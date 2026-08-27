# XML.jl v0.4 — Performance

The headline cross-library figures live in the [README](README.md#benchmarks). This document is the decomposition behind them — what XML.jl does by access pattern, and the theory that makes the lexer and parser "optimal".

## The theory behind "optimal"

XML parsing splits into two language-theory levels, and v0.4 hits the **asymptotic lower bound** of each — the sense in which the lexer and parser are "optimal". The gap to a C library like [libxml2](https://en.wikipedia.org/wiki/Libxml2) is constant-factor (C tuning, a leaner non-Julia-heap tree), not asymptotic — and only on the pointer-tree `Node` build; `FlatNode` builds faster than libxml2 (Table 5), and at streaming XML.jl is ~2.5× *faster* (Table 1).

### Level 1 — lexing is finite-state

The token grammar (tags, attributes, text, comments, CDATA, PIs) is [regular](https://en.wikipedia.org/wiki/Regular_language), so the tokenizer is a [DFA](https://en.wikipedia.org/wiki/Deterministic_finite_automaton) (the `Mode` enum is its start-condition states): **one pass, O(n) time, O(1) state** — no lexer can do better.

The implementation hits that bound:

- a `Token` is [`isbits`](https://docs.julialang.org/en/v1/base/base/#Base.isbitstype) (a kind plus a byte range), so token emission **allocates nothing** (measured: 0 B) — and stays unboxed even inside small unions such as an iterator's `Union{Token, Nothing}`, per Julia's [isbits-Union optimizations](https://docs.julialang.org/en/v1/devdocs/isbitsunionarrays/);
- delimiter scans use `findnext`, which for `String` calls the C library's [`memchr`](https://man7.org/linux/man-pages/man3/memchr.3.html) — a hand-vectorized (SIMD) byte search, so the hot scan runs at memory speed rather than as a byte-at-a-time Julia loop;
- whether a byte may appear in an XML name is answered by a single load from a **256-entry lookup table** instead of a chain of range comparisons.

The one departure from pure finite-state scanning is the DOCTYPE body: its internal subset `[…]` may itself contain `>`, so a bracket-depth counter determines which `>` actually closes the DOCTYPE.

### Level 2 — nesting is visibly pushdown

Balanced `<a>…</a>` isn't regular — matching open to close needs a stack. XML's *nesting structure* is a [nested word / visibly pushdown language](https://en.wikipedia.org/wiki/Nested_word) — XML being the canonical example in Alur & Madhusudan's papers introducing the class: open/close tags are *visible* call/return markers, so the stack action is fixed by token kind alone — `OPEN_TAG` pushes, `CLOSE_TAG` and self-closing `<a/>` pop, the rest is internal — no lookahead, no backtracking.\
So `_parse` is a single-pass **[visibly pushdown automaton](https://en.wikipedia.org/wiki/Nested_word#Automata)** (VPA): **O(n) time, stack depth = nesting depth** (building the output tree is a second, separable O(n) cost — the one `Cursor` skips entirely, and the one Table 3 prices).\
Drive the same traversal event-by-event and you have the `Cursor` streaming API — pure Julia: no [FFI](https://en.wikipedia.org/wiki/Foreign_function_interface) call per event, unlike a libxml2-backed reader (EzXML's `StreamReader`), where every pulled event crosses the Julia↔C boundary.

One theoretical fine print: a textbook VPA has a *finite* stack alphabet, while checking that `</a>` really closes `<a>` pushes the tag *name* — drawn from an unbounded set of names — so the parser is formally a VPA over an unbounded stack alphabet. A nuance of classification only: each stack entry holds a tag name, the close-tag comparison is O(name length) and already inside the O(n), and every guarantee above holds.

### Julia-level constant factors

The well-formedness level is a type parameter (`Val{W}`), so `:strict`/`:structural` checks are [dead-code-eliminated](https://en.wikipedia.org/wiki/Dead-code_elimination) when inactive (confirmed in the LLVM); `Node{S}` is parametric, so `parse(s, Node{SubString{String}})` — a supported method, exercised by the test suite and by the benchmarks behind the zero-copy row below — keeps **zero-copy views** while `parse(s, Node)` owns `String`s; a `has_entities` flag skips entity decoding when a token holds no `&`; and tokens are native byte spans — every span edge the scanner produces falls on an ASCII byte, provably a UTF-8 character boundary, so token views are rebuilt by direct field construction with no index walking.

## By access pattern

Performance isn't one number — it splits by *what you do with the document*. 14 MB [XMark](https://projects.cwi.nl/xmark/) file (XML.jl and EzXML walk the same ~882 K nodes); **lower is better.**

> [!NOTE]
> **How to read the timings.** Every timing on this page is a BenchmarkTools
> `@benchmark` measurement at default parameters: samples run back-to-back from a warm,
> compiled state, and the quoted number is the median sample, with the median
> garbage-collection share as its *(GC x)* tail (omitted below 0.05 ms). The GC share
> is the volatile part of a Julia timing — it moves with the heap state a session
> inherits — while the number minus its GC share reproduces within a few percent and is
> the one to compare across sessions or versions. Allocation totals and retained sizes
> are deterministic facts, identical under any protocol.

### Stream — events, no tree

`Cursor` pulls in pure Julia — a full pass, decoded reads included, leaves the allocator
untouched; EzXML's `StreamReader` is libxml2's reader, at one FFI call per event:

| Stream | time (incl. GC) | memory |
|---|--:|--:|
| **XML.jl `Cursor`** | **26 ms** | **0.0 MiB** |
| EzXML `StreamReader` | 71 ms (GC 0.6) | 36 MiB |

_Table 1 — streaming: events only, no tree built._[^profile]

Structured pull helpers keep scans cheap without hand-tracked depth: `for_each_child` applies a function to the *immediate* children of the current node (nestable — composing calls yields a full depth-first walk), and `skip_element!` jumps a whole subtree in one byte-level scan, so structural walks classify nodes without tokenizing their contents.

### Partial reads — `LazyNode`

Opening builds nothing — for a document held as a `String` it costs one scan of the source for line ends, 0.21 ms on this 14 MB file, and for one held as anything else not even that ([Memory-mapped sources](#memory-mapped-sources)) — and nothing is ever cached: each visit re-tokenizes and rebuilds its small handles — iteration steps allocate nothing, and each child or attribute scan is one small resumable cursor object, elided when it never loops (Table 4 prices the full-scan case) — so a repeated look-up costs only its re-scan time, and costs repeat per visit. A traversal costs only the bytes it actually steps over: the child iterator defers a yielded element's subtree skip until the *next sibling* is requested, so descending to a target is O(bytes before it); scanning *everything* is the worst case, priced per reader in Table 4. What still costs: *horizontal* scans cost the subtrees they step past (as any index-free forward reader must), and *repeated* look-ups cost again — those two patterns tip the scale toward `FlatNode`/`Node`.

> [!NOTE]
> Ask only for what you need: a `for` loop over `eachchildnode` fetches the next sibling — and runs its predecessor's deferred subtree skip — at the top of each round, so exit *from within the body* once you are done:
>
> ```julia
> out = LazyNode[]                  # goal: keep the first three children
> for c in eachchildnode(parent)
>     push!(out, c)
>     length(out) == 3 && break     # the break is in the body — no fourth fetch
> end
> ```
>
> Move that test to the top of the body instead — `length(out) == 3 && break; push!(out, c)` — and the loop only breaks at round *four*, whose fetch has already performed the third child's deferred subtree skip.

### Memory-mapped sources

The readers keep whatever string type the document arrives as, and a document not held as a `String` is never rewritten when it is read in — so a `StringView` over `Mmap`, the recipe for files too large to hold in memory, reaches the reader intact whatever the file's line ends. The line-end normalization the specification requires then happens on each value as it is reported, which costs a copy only for the values that carry a line end, and only for the ones actually asked for. On the same XMark corpus, mapped instead of read, with CR LF line ends throughout — the worst case for this, since every line end is one CR to fold:

| | time | allocated |
|---|--:|--:|
| open | **11.9 ns** | 176 B |
| open, then read 1 000 nodes | 43.8 µs | 38 KiB |
| open, then read every node | 40.6 ms | 36.3 MiB |

An LF file opens in the same 11.7 ns: the entry does not scan the source, so opening is O(1) in the file's size and a reader that touches a fraction of a mapped document costs only that fraction. Reading *all* of a CR LF document allocates more than a reader working from a rewritten `String` would. These are short-lived strings, reclaimed by the garbage collector as the reader moves on, where the rewrite holds one document-sized block for as long as any handle into it lives. For a file larger than memory, that difference determines whether it can be read at all.[^mapped]

[^mapped]: Measured 2026-08-25, same machine and settings as the rest, Julia 1.12.7; BenchmarkTools medians. Source: [`benchmarks/profile.jl`](benchmarks/profile.jl), section (5), which generates the CR LF twin of the corpus beside it.

### Full DOM — parse + walk everything

libxml2 is fastest to build; XML.jl materialises an 882 K-node Julia tree, EzXML a leaner C one:

| Full DOM extract | time (incl. GC) | memory |
|---|--:|--:|
| EzXML (libxml2) | **60 ms** | **54 MiB** |
| LightXML (elements only) | 65 ms (GC 1.4) | 57 MiB |
| XML.jl (`SubString`, zero-copy) | 79 ms (GC 30) | 95 MiB |
| XML.jl (`String`) | 79 ms (GC 25) | 100 MiB |
| XML.jl **v0.3.9** (previous release) | 530 ms | 1422 MiB |

_Table 2 — full-DOM extraction (parse + pull every tag/text), cross-library._[^profile]

**Decomposed** (XML.jl, the `String` variant — every row a direct measurement; the lex is the first stage *inside* the parse row, so their difference prices the tree build, and parse + traverse reproduces the Table 2 row within noise):

| Stage | time (incl. GC) | allocated |
|---|--:|--:|
| read file (I/O) | 0.6 ms | — |
| **lex — the DFA** | **23.4 ms** | **0 B** |
| parse → DOM (lex + build the tree, the VPA) | 62.5 ms (GC 13) | 100 MiB |
| traverse a built tree | 4.2 ms | 0 B |

_Table 3 — the XML.jl pipeline, decomposed (`String` variant)._[^profile]

The lexer is allocation-free; **the whole libxml2 gap is *materialising* the native tree, not scanning it** — and the GC column shows where that cost lives: the allocation-free lex cannot trigger a collection, so every garbage-collector pause inside a parse falls in the build, the toll of 882 K fresh objects.

Traversal of a pre-built tree stays off the allocator where it counts — iteration *steps*
are free for all three readers, and the allocation column is measured, not assumed. `Node`
and `FlatNode` allocate nothing at all; `LazyNode` allocates one small object per container
node — its resumable child cursor, elided by the compiler wherever a container is empty:

| Whole-tree traversal (same recursive function) | time (incl. GC) | allocations |
|---|--:|--:|
| `FlatNode` | 3.8 ms | 0 |
| `Node` | 4.1 ms | 0 |
| `LazyNode` | 138 ms (GC 0.4) | 272,762 |
| `LazyNode`, adding the attribute sweep | 146 ms (GC 0.4) | 272,762 |

_Table 4 — whole-tree traversal per reader: one child iterator and a tag + value read per
visited node (the spreadsheet hot-loop shape). `LazyNode` re-tokenizes everything it steps
over — a cost per visit by design; see the partial-reads section for the access patterns it suits._[^profile]

### `FlatNode` (v0.4.2, experimental)

One contiguous array of isbits records with index links instead of per-node pointers — an eager *read-only* alternative to the pointer-tree `Node`.

Most of its advantage is a better *constant factor*: it does the same O(n) work as the `Node` build, just with denser packing, no per-node allocation, and no Julia-GC mark-rescan of millions of objects.

The asymptotics change only in the [external-memory model](https://en.wikipedia.org/wiki/External_memory_algorithm) ([Aggarwal–Vitter 1988](https://dl.acm.org/doi/10.1145/48529.48535)) — the model of a *two-level memory hierarchy*, formulated for disk vs RAM and applied here to CPU cache vs RAM: it counts memory-block *transfers* instead of instructions, with **B** defined as how many records fit in one transferred block. A document-order scan of a contiguous store moves Θ(n/B) blocks — one per block-full of records — while a pointer tree *scattered* across the heap can move up to Θ(n), one per node.

Concretely, a `_FlatRec` is 40 bytes — ten `Int32`-sized fields (kind, three tree links, tag span, value span, attribute range; 32-bit throughout because the 2 GiB source bound lets every offset and index fit an `Int32`, halving the store) — so a 64–128-byte cache line carries one to three records.

And the scan is [*cache-oblivious*](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm) ([Frigo et al. 1999](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm)): sequential access is Θ(n/B) for *every* B simultaneously, so neither the code nor the analysis needs the actual line size — the bound holds at each level of the cache hierarchy at once, hardware prefetchers included.

Measured on the same XMark document:

| Full DOM, per reader | build (incl. GC) | walk every node | extract all values | DOM size in memory |
|---|--:|--:|--:|--:|
| **`FlatNode`** | **27.2 ms (GC 0.1)** | **2.97 ms** | **3.1 ms** | **54.9 MiB** |
| `Node` | 70.7 ms (GC 23) | 3.46 ms | 3.7 ms | 71.6 MiB |
| EzXML (libxml2) | 46.6 ms | — | — | — |

_Table 5 — per-reader full-DOM comparison; *build* is the whole `parse` call, and *DOM size* is the **retained** live tree (`Base.summarysize`), not allocations._[^flatbench]

Build allocations: 42.2 MiB (`FlatNode`) vs 99.8 MiB (`Node`), and on the *build* `FlatNode` is ~1.7× faster than libxml2 itself, `Node` ~1.5× slower than the C library. The GC cells say why `FlatNode` builds so cheaply: its build allocates a handful of arrays instead of 882 K objects, so its median GC share is ~0.1 ms where `Node`'s is ~23 ms. Access on the finished stores: whole-tree walks are close (2.97 vs 3.46 ms — exact-size children vectors keep `Node`'s locality sharp), `parent`/`depth` stay O(1) index hops on `FlatNode` where `Node` must search down from the root, and pure value extraction is close too, flat store slightly faster (3.1 vs 3.7 ms — a per-value `SubString` view costs two integer stores).

### Choosing

Stream / low-memory / read-only full-DOM / repeated traversal → **XML.jl**; `FlatNode` builds ~1.7× faster than the libxml2 binder (27.2 vs 46.6 ms), and the C library's one advantage is the one-shot *`Node`* build-and-extract (~1.3× end-to-end, Table 2) — either way, pure Julia, no C dependency. Against its own past, v0.4 is **~7× faster and ~14× leaner than 0.3.9** (530 → 79 ms and ~1.4 GiB → 100 MiB on this file, Table 2) — see [`benchmarks/profile.jl`](benchmarks/profile.jl), [`benchmarks/profile_vs_039.jl`](benchmarks/profile_vs_039.jl), [`benchmarks/compare.jl`](benchmarks/compare.jl).

> [!NOTE]
> **`:strict`** adds a character-range scan over text (a second O(content) pass); the overhead scales with the document's *text share* — ~1.1× on the markup-heavy XMark corpus, up to ~20× on a pure-text document; `:lenient` / `:structural` are unaffected.

> [!TIP]
> **GC tuning for tree-holding applications.** A single-threaded Julia process defaults to
> *one* GC thread; `--gcthreads=4` (the performance-core count here) parallelizes the mark
> phase, cutting a full collection with this corpus's 882 K-node `Node` tree live from
> ~56 ms to ~20 ms (median `@benchmark GC.gc(true)` sample; the `--gc-only` mode of
> [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl) reproduces the pair) —
> and the build's GC share shrinks accordingly. Mark threads sleep outside collections
> and run only while compute is paused anyway, so the setting takes nothing from
> computation. It trims GC pauses, not the materialization floor: the build's GC-free work
> is unchanged.

[^profile]: Tables 1–3: measured 2026-08-04; Table 4: measured 2026-08-11 (the `v0.3.9` row: 2026-06-28) — same machine and settings throughout: Apple M5 (single-threaded), Julia 1.12.6; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3); BenchmarkTools at a 5 s budget per cell. Source: [`benchmarks/profile.jl`](benchmarks/profile.jl).

[^flatbench]: Table 5 (and the README access-pattern table): measured 2026-08-04, same machine, Julia and BenchmarkTools settings; source [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl).
