# XML.jl v0.4 — Performance

The headline cross-library figures live in the [README](README.md#benchmarks). This document is the decomposition behind them — what XML.jl does by access pattern, and the theory that makes the lexer and parser "optimal".

## The theory behind "optimal"

XML parsing splits into two language-theory levels, and v0.4 hits the **asymptotic lower bound** of each — the sense in which the lexer and parser are "optimal". The gap to a C library like [libxml2](https://en.wikipedia.org/wiki/Libxml2) is constant-factor (C tuning, a leaner non-Julia-heap tree), not asymptotic — and only on full-DOM building; at streaming, XML.jl is *faster* (below).

### Level 1 — lexing is finite-state

The token grammar (tags, attributes, text, comments, CDATA, PIs) is [regular](https://en.wikipedia.org/wiki/Regular_language), so the tokenizer is a [DFA](https://en.wikipedia.org/wiki/Deterministic_finite_automaton) (the `Mode` enum is its start-condition states): **one pass, O(n) time, O(1) state** — no lexer can do better. The implementation hits it: a `Token` is [`isbits`](https://docs.julialang.org/en/v1/base/base/#Base.isbitstype) (a kind plus a byte range), so token emission **allocates nothing** (measured: 0 B) — and stays unboxed even inside small unions such as an iterator's `Union{Token, Nothing}`, per Julia's [isbits-Union optimizations](https://docs.julialang.org/en/v1/devdocs/isbitsunionarrays/); delimiter scans use `findnext`, which for `String` calls the C library's [`memchr`](https://man7.org/linux/man-pages/man3/memchr.3.html) — a hand-vectorized (SIMD) byte search, so the hot scan runs at memory speed rather than as a byte-at-a-time Julia loop; and whether a byte may appear in an XML name is answered by a single load from a **256-entry lookup table** instead of a chain of range comparisons. (The one departure from pure finite-state scanning is the DOCTYPE body: its internal subset `[…]` may itself contain `>`, so a bracket-depth counter decides which `>` actually closes the DOCTYPE.)

### Level 2 — nesting is visibly pushdown

Balanced `<a>…</a>` isn't regular — matching open to close needs a stack. XML's *nesting structure* is a [nested word / visibly pushdown language](https://en.wikipedia.org/wiki/Nested_word) — XML being the canonical example in Alur & Madhusudan's papers introducing the class: open/close tags are *visible* call/return markers, so the stack action is fixed by token kind alone — `OPEN_TAG` pushes, `CLOSE_TAG` and self-closing `<a/>` pop, the rest is internal — no lookahead, no backtracking. So `_parse` is a single-pass **[visibly pushdown automaton](https://en.wikipedia.org/wiki/Nested_word#Automata)** (VPA): **O(n) time, stack depth = nesting depth** (the tree it builds is the separate O(n) cost). Drive the same traversal event-by-event and you have the `Cursor` streaming API — pure Julia: no [FFI](https://en.wikipedia.org/wiki/Foreign_function_interface) call per event, unlike a libxml2-backed reader (EzXML's `StreamReader`), where every pulled event crosses the Julia↔C boundary. (One theoretical fine print: a textbook VPA has a *finite* stack alphabet, while checking that `</a>` really closes `<a>` pushes the tag *name* — drawn from an unbounded set of names — so the parser is formally a VPA over an unbounded stack alphabet; the guarantees that matter — one pass, O(n) time, stack depth = nesting depth — are unaffected.)

### Julia-level constant factors

The well-formedness level is a type parameter (`Val{W}`), so `:strict`/`:structural` checks are [dead-code-eliminated](https://en.wikipedia.org/wiki/Dead-code_elimination) when inactive (confirmed in the LLVM); `Node{S}` is parametric, so `parse(s, Node{SubString{String}})` — a supported method, exercised by the test suite and by the benchmarks behind the zero-copy row below — keeps **zero-copy views** while `parse(s, Node)` owns `String`s; a `has_entities` flag skips entity decoding when a token holds no `&`.

## By access pattern

Performance isn't one number — it splits by *what you do with the document*. 14 MB [XMark](https://projects.cwi.nl/xmark/) file (XML.jl and EzXML walk the same ~882 K nodes); **lower is better.**

### Stream — events, no tree

`Cursor` pulls in pure Julia; EzXML's `StreamReader` is libxml2's reader, paying FFI per event:

| Stream | time | memory |
|---|--:|--:|
| **XML.jl `Cursor`** | **54 ms** | **17 MiB** |
| EzXML `StreamReader` | 67 ms | 35 MiB |

_Table 1 — streaming: events only, no tree built._

Structured pull helpers keep scans cheap without hand-tracked depth: `for_each_child` applies a function to the *immediate* children of the current node (nestable — composing calls yields a full depth-first walk), and `skip_element!` jumps a whole subtree in one byte-level scan, so structural walks classify nodes without tokenizing their contents.

### Partial reads — `LazyNode`

Opening is a no-op wrapper (~0.5 µs on this 14 MB file) and nothing is ever cached: each visit re-tokenizes and rebuilds its small handles (~1 KB allocated per repeated look-up), so costs repeat per visit. Partial reads are cheap when the *touched* nodes have small spans — leaf-ward hops, flat or kilobyte-scale documents (typical web-service responses parse in well under a millisecond) — and *repeated* look-ups tip the scale toward `FlatNode`/`Node`.

> [!NOTE]
> **As of v0.4.2**, yielding a child *pre-skips* (tokenizes) that child's whole subtree to position for its sibling — so merely touching this document's root element costs ~35 ms (its subtree is nearly the whole file), and a 9-node descent to the first `<item>` ~50 ms: on a document dominated by one huge container, a `FlatNode`/`Node` build amortizes almost immediately.

### Full DOM — parse + walk everything

libxml2 wins the build; XML.jl materialises an 882 K-node Julia tree, EzXML a leaner C one:

| Full DOM extract | time | memory |
|---|--:|--:|
| EzXML (libxml2) | **61 ms** | **54 MiB** |
| LightXML (elements only) | 63 ms | 57 MiB |
| XML.jl (`SubString`, zero-copy) | 103 ms | 120 MiB |
| XML.jl (`String`) | 115 ms | 122 MiB |
| XML.jl **v0.3.9** (previous release) | 530 ms | 1422 MiB |

_Table 2 — full-DOM extraction (parse + pull every tag/text), cross-library._

**Decomposed** (XML.jl, the `String` variant — the stages sum to its Table 2 row):

| Stage | time | allocated |
|---|--:|--:|
| read file (I/O) | 0.6 ms | — |
| **lex — the DFA** | **36 ms** | **0 B** |
| build the tree — the VPA | ~73 ms | 122 MiB |
| traverse a built tree | 7 ms | 0 B |

_Table 3 — the XML.jl pipeline, decomposed (`String` variant)._

The lexer is allocation-free; **the whole libxml2 gap is *materialising* the native tree, not scanning it**. Nor are the build's ~73 ms all construction: ~26 ms *of* them are garbage-collector pauses (BenchmarkTools' per-sample GC time) — the allocation-free lex cannot trigger a collection, so every GC pause inside a parse lands in the build, the toll of 882 K fresh objects.

### `FlatNode` (v0.4.2, experimental)

One contiguous array of isbits records with index links instead of per-node pointers — an eager *read-only* alternative to the pointer-tree `Node`. Most of its advantage is a better *constant factor*: it does the same O(n) work as the `Node` build, just with denser packing, no per-node allocation, and no Julia-GC mark-rescan of millions of objects. The asymptotics change only in the [external-memory model](https://en.wikipedia.org/wiki/External_memory_algorithm) ([Aggarwal–Vitter 1988](https://dl.acm.org/doi/10.1145/48529.48535)) — the model of a *two-level memory hierarchy*, formulated for disk vs RAM and applied here to CPU cache vs RAM: it counts memory-block *transfers* instead of instructions, with **B** defined as how many records fit in one transferred block. A document-order scan of a contiguous store moves Θ(n/B) blocks — one per block-full of records — while a pointer tree *scattered* across the heap can move up to Θ(n), one per node. Concretely, a `_FlatRec` is 40 bytes — ten `Int32`-sized fields (kind, three tree links, tag span, value span, attribute range; 32-bit throughout because the 2 GiB source bound lets every offset and index fit an `Int32`, halving the store) — so a 64–128-byte cache line carries one to three records. And the scan is [*cache-oblivious*](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm) ([Frigo et al. 1999](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm)): sequential access achieves Θ(n/B) for *every* B simultaneously, so neither the code nor the analysis needs the actual line size — the bound holds at each level of the cache hierarchy at once, hardware prefetchers included. Measured on the same XMark document:

| Full DOM, per reader | build | walk every node | extract all values | DOM size in memory |
|---|--:|--:|--:|--:|
| **`FlatNode`** | **51.8 ms** | **2.97 ms** | 10.6 ms | **54.9 MiB** |
| `Node` | 99.9 ms | 6.3 ms | **6.5 ms** | 80.0 MiB |
| EzXML (libxml2) | 37.7 ms | — | — | — |

_Table 4 — per-reader full-DOM comparison (median of repeated runs, default settings); *build* is the whole `parse` call, and *DOM size* is the **retained** live tree (`Base.summarysize`), not allocations._

Build allocations: 73.7 MiB (`FlatNode`) vs 122.3 MiB (`Node`), and the libxml2 *build* gap narrows from ~2.7× to ~1.4×. Beyond the cheaper build, access itself is faster on `FlatNode`: full walks run ~2× faster (the contiguous scan), and `parent`/`depth` are O(1) index hops where `Node` must search down from the root. The one pattern where `Node` keeps an edge is pure value extraction on an already-built tree (6.5 vs 10.6 ms): direct field reads beat computed `SubString` views.

### Choosing

Stream / low-memory / read-only full-DOM / repeated traversal → **XML.jl**; a one-shot build-and-extract is the one job where a libxml2 binder still builds ~1.4× faster (was ~2.7× before `FlatNode`) — either way, pure Julia, no C dependency. Against its own past, v0.4 is **~5× faster and ~12× leaner than 0.3.9** (which used ~1.4 GiB for this file) — see [`benchmarks/profile.jl`](benchmarks/profile.jl), [`benchmarks/profile_vs_039.jl`](benchmarks/profile_vs_039.jl), [`benchmarks/compare.jl`](benchmarks/compare.jl).

> [!NOTE]
> **`:strict`** adds a character-range scan over text (a second O(content) pass); the overhead scales with the document's *text share* — ~1.1× on the markup-heavy XMark corpus, up to ~20× on a pure-text document; `:lenient` / `:structural` are unaffected.

---

_Tables 1–3: measured 2026-07-22 (the `v0.3.9` row: 2026-06-28), Apple M5 (single-threaded), Julia 1.12.6; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3). Source: [`benchmarks/profile.jl`](benchmarks/profile.jl). Table 4: measured 2026-07-22, same machine and Julia; source [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl)._
