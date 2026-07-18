# XML.jl v0.4 — Performance

The headline cross-library figures live in the [README](README.md#benchmarks). This document is the decomposition behind them — what XML.jl does by access pattern, and the theory that makes the lexer and parser "optimal".

XML parsing splits into two language-theory levels, and v0.4 hits the **asymptotic lower bound** of each — the sense in which the lexer and parser are "optimal". The gap to a C library like [libxml2](https://en.wikipedia.org/wiki/Libxml2) is constant-factor (C tuning, a leaner non-Julia-heap tree), not asymptotic — and only on full-DOM building; XML.jl is *faster* streaming (below).

**Level 1 — lexing is finite-state.** The token grammar (tags, attributes, text, comments, CDATA, PIs) is [regular](https://en.wikipedia.org/wiki/Regular_language), so the tokenizer is a [DFA](https://en.wikipedia.org/wiki/Deterministic_finite_automaton) (the `Mode` enum is its start-condition states): **one pass, O(n) time, O(1) state** — no lexer can do better. The implementation hits it: a `Token` is [`isbits`](https://docs.julialang.org/en/v1/base/base/#Base.isbitstype) (a kind plus a byte range), so token emission **allocates nothing** (measured: 0 B); delimiter scans use `findnext`, which lowers to [`memchr`](https://man7.org/linux/man-pages/man3/memchr.3.html); name bytes classify through a **256-entry lookup table**. (The lone exception is the DOCTYPE body, where a `[…]` depth counter stops a `>` inside it from closing early.)

**Level 2 — nesting is visibly pushdown.** Balanced `<a>…</a>` isn't regular — matching open to close needs a stack. XML's *nesting structure* is a [nested word / visibly pushdown language](https://en.wikipedia.org/wiki/Nested_word) (Alur & Madhusudan's canonical example): open/close tags are *visible* call/return markers, so the stack action is fixed by token kind alone — `OPEN_TAG` pushes, `CLOSE_TAG` and self-closing `<a/>` pop, the rest is internal — no lookahead, no backtracking. So `_parse` is a single-pass **visibly pushdown automaton**: **O(n) time, stack depth = nesting depth** (the tree it builds is the separate O(n) cost). Drive the same traversal event-by-event and you have the `Cursor` streaming API — pure Julia, no [FFI](https://en.wikipedia.org/wiki/Foreign_function_interface) per event. (Matching closes to opens *by name* uses an unbounded stack alphabet — technically past a finite-alphabet VPA — but the linear-time, depth-bounded guarantees hold.)

**Julia-level constant factors.** The well-formedness level is a type parameter (`Val{W}`), so `:strict`/`:structural` checks are [dead-code-eliminated](https://en.wikipedia.org/wiki/Dead-code_elimination) when inactive (confirmed in the LLVM); `Node{S}` is parametric, so `parse(s, Node{SubString{String}})` keeps **zero-copy views** while `parse(s, Node)` owns `String`s; a `has_entities` flag skips entity decoding when a token holds no `&`.

## By access pattern

Performance isn't one number — it splits by *what you do with the document*. 14 MB [XMark](https://projects.cwi.nl/xmark/) file (XML.jl and EzXML walk the same ~882 K nodes); **lower is better.**

**Stream** (events, no tree) — `Cursor` pulls in pure Julia; EzXML's `StreamReader` is libxml2's reader, paying FFI per event:

| Stream | time | memory |
|---|--:|--:|
| **XML.jl `Cursor`** | **54 ms** | **17 MiB** |
| EzXML `StreamReader` | 67 ms | 35 MiB |

Structured pull helpers keep scans cheap without hand-tracked depth: `for_each_child` applies a function to the *immediate* children of the current node (nestable — composing calls yields a full depth-first walk), and `skip_element!` jumps a whole subtree in one byte-level scan, so structural walks classify nodes without tokenizing their contents.

**Partial reads** (`LazyNode`) — opening is a no-op wrapper (~0.5 µs on this 14 MB file) and nothing is ever cached: each visit re-tokenizes and rebuilds its small handles (~1 KB allocated per repeated look-up), so costs repeat per visit. One measured caveat shapes the pattern: yielding a child currently *pre-skips* (tokenizes) that child's whole subtree to position for its sibling, so merely touching this document's root element costs ~35 ms (its subtree is nearly the whole file) and a 9-node descent to the first `<item>` ~50 ms. Partial reads are therefore cheap when the *touched* nodes have small spans — leaf-ward hops, flat or kilobyte-scale documents (typical web-service responses parse in well under a millisecond) — while on a document dominated by one huge container, a `FlatNode`/`Node` build amortizes almost immediately, and *repeated* look-ups tip the scale even faster.

**Full DOM** (parse + walk everything) — libxml2 wins the build; XML.jl materialises an 882 K-node Julia tree, EzXML a leaner C one:

| Full DOM extract | time | memory |
|---|--:|--:|
| EzXML (libxml2) | **62 ms** | **54 MiB** |
| LightXML (elements only) | 62 ms | 57 MiB |
| XML.jl (`SubString`, zero-copy) | 110 ms | 120 MiB |
| XML.jl (`String`) | 135 ms | 122 MiB |
| XML.jl **v0.3.9** (previous release) | 530 ms | 1422 MiB |

**Decomposed** (XML.jl):

| Stage | time | allocated |
|---|--:|--:|
| read file (I/O) | 0.6 ms | — |
| **lex — the DFA** | **37 ms** | **0 B** |
| build the tree — the VPA | ~70 ms | 122 MiB |
| traverse a built tree | 6 ms | 0 B |

The lexer is allocation-free; **the whole libxml2 gap is *materialising* the native tree, not scanning it**.

**`FlatNode` (v0.4.2, experimental).** One contiguous array of isbits records with index links instead of per-node pointers — an eager *read-only* alternative to the pointer-tree `Node`. Most of its advantage is a better *constant factor*: it does the same O(n) work as the `Node` build, just with denser packing, no per-node allocation, and no Julia-GC mark-rescan of millions of objects. The asymptotics change only in the [external-memory model](https://en.wikipedia.org/wiki/External_memory_algorithm) ([Aggarwal–Vitter 1988](https://dl.acm.org/doi/10.1145/48529.48535)) — the model of a *two-level memory hierarchy*, formulated for disk vs RAM and applied here to CPU cache vs RAM: it counts memory-block *transfers* instead of instructions, with **B** defined as how many records fit in one transferred block. A document-order scan of a contiguous store moves Θ(n/B) blocks — one per block-full of records — while a pointer tree *scattered* across the heap can move up to Θ(n), one per node. Concretely, a `_FlatRec` is 40 bytes — ten `Int32`-sized fields (kind, three tree links, tag span, value span, attribute range; 32-bit throughout because the 2 GiB source bound lets every offset and index fit an `Int32`, halving the store) — so a 64–128-byte cache line carries one to three records. And the scan is [*cache-oblivious*](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm) ([Frigo et al. 1999](https://en.wikipedia.org/wiki/Cache-oblivious_algorithm)): sequential access achieves Θ(n/B) for *every* B simultaneously, so neither the code nor the analysis needs the actual line size — the bound holds at each level of the cache hierarchy at once, hardware prefetchers included. Measured on the same XMark document:

| Full DOM, per reader | build | walk every node | extract all values | DOM size in memory |
|---|--:|--:|--:|--:|
| **`FlatNode`** | **50.5 ms** | **2.98 ms** | 10.2 ms | **54.9 MiB** |
| `Node` | 93.7 ms | 5.8 ms | **6.3 ms** | 80.0 MiB |
| EzXML (libxml2) | 37.9 ms | — | — | — |

Build allocations: 73.7 MiB (`FlatNode`) vs 122.3 MiB (`Node`), and the libxml2 *build* gap narrows from ~2–3× to ~1.3×. Beyond the cheaper build, access itself is faster on `FlatNode`: full walks run ~2× faster (the contiguous scan), and `parent`/`depth` are O(1) index hops where `Node` must search down from the root. The one pattern where `Node` keeps an edge is pure value extraction on an already-built tree (6.3 vs 10.2 ms): direct field reads beat computed `SubString` views.

**Choose by access pattern:** stream / low-memory / read-only full-DOM / repeated traversal → **XML.jl**; a one-shot build-and-extract is the one job where a libxml2 binder still builds ~1.3× faster (was ~2–3× before `FlatNode`) — either way, pure Julia, no C dependency. Against its own past, v0.4 is **~4.8× faster and ~12× leaner than 0.3.9** (which used ~1.4 GiB for this file) — see [`benchmarks/profile.jl`](benchmarks/profile.jl), [`benchmarks/profile_vs_039.jl`](benchmarks/profile_vs_039.jl), [`benchmarks/compare.jl`](benchmarks/compare.jl).

> **`:strict`** adds a character-range scan over text (a second O(content) pass), ~8× slower than `:structural` on text-heavy input; `:lenient` / `:structural` are unaffected.

---

_Measured 2026-06-28/29, Apple M5 (single-threaded), Julia 1.12.6; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3), XMLDict 0.4.2. Sources: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl), [`benchmarks/profile.jl`](benchmarks/profile.jl). The `FlatNode` table: measured 2026-07-17, XML.jl 0.4.2, same machine and Julia; source [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl)._
