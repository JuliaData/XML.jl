# XML.jl v0.4 — Performance

The headline cross-library figures live in the [README](README.md#benchmarks). This document is the decomposition behind them — what XML.jl does by regime, and the theory that makes the lexer and parser "optimal".

XML parsing splits into two language-theory levels, and v0.4 hits the **asymptotic lower bound** of each — the sense in which the lexer and parser are "optimal". The gap to a C library like [libxml2](https://en.wikipedia.org/wiki/Libxml2) is constant-factor (C tuning, a leaner non-Julia-heap tree), not asymptotic — and only on full-DOM building; XML.jl is *faster* streaming (below).

**Level 1 — lexing is finite-state.** The token grammar (tags, attributes, text, comments, CDATA, PIs) is [regular](https://en.wikipedia.org/wiki/Regular_language), so the tokenizer is a [DFA](https://en.wikipedia.org/wiki/Deterministic_finite_automaton) (the `Mode` enum is its start-condition states): **one pass, O(n) time, O(1) state** — no lexer can do better. The implementation hits it: a `Token` is [`isbits`](https://docs.julialang.org/en/v1/base/base/#Base.isbitstype) (a kind plus a byte range), so token emission **allocates nothing** (measured: 0 B); delimiter scans use `findnext`, which lowers to [`memchr`](https://man7.org/linux/man-pages/man3/memchr.3.html); name bytes classify through a **256-entry lookup table**. (The lone exception is the DOCTYPE body, where a `[…]` depth counter stops a `>` inside it from closing early.)

**Level 2 — nesting is visibly pushdown.** Balanced `<a>…</a>` isn't regular — matching open to close needs a stack. XML's *nesting structure* is a [nested word / visibly pushdown language](https://en.wikipedia.org/wiki/Nested_word) (Alur & Madhusudan's canonical example): open/close tags are *visible* call/return markers, so the stack action is fixed by token kind alone — `OPEN_TAG` pushes, `CLOSE_TAG` and self-closing `<a/>` pop, the rest is internal — no lookahead, no backtracking. So `_parse` is a single-pass **visibly pushdown automaton**: **O(n) time, stack depth = nesting depth** (the tree it builds is the separate O(n) cost). Drive the same traversal event-by-event and you have the `Cursor` streaming API — pure Julia, no [FFI](https://en.wikipedia.org/wiki/Foreign_function_interface) per event. (Matching closes to opens *by name* uses an unbounded stack alphabet — technically past a finite-alphabet VPA — but the linear-time, depth-bounded guarantees hold.)

**Julia-level constant factors.** The well-formedness level is a type parameter (`Val{W}`), so `:strict`/`:structural` checks are [dead-code-eliminated](https://en.wikipedia.org/wiki/Dead-code_elimination) when inactive (confirmed in the LLVM); `Node{S}` is parametric, so `parse(s, Node{SubString{String}})` keeps **zero-copy views** while `parse(s, Node)` owns `String`s; a `has_entities` flag skips entity decoding when a token holds no `&`.

## By regime

Performance isn't one number — it splits by *what you do with the document*. 14 MB [XMark](https://projects.cwi.nl/xmark/) file (XML.jl and EzXML walk the same ~882 K nodes); **lower is better.**

**Stream** (events, no tree) — `Cursor` pulls in pure Julia; EzXML's `StreamReader` is libxml2's reader, paying FFI per event:

| Stream | time | memory |
|---|--:|--:|
| **XML.jl `Cursor`** | **54 ms** | **17 MiB** |
| EzXML `StreamReader` | 67 ms | 35 MiB |

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

The lexer is allocation-free; **the whole libxml2 gap is *materialising* the native tree, not scanning it** — which a future flat node store (one contiguous array of records, index links instead of per-node pointers) could close, as an eager alternative to the pointer-tree `Node`. Its edge would be mostly constant-factor (denser packing, no per-node allocation, no Julia-GC mark-rescan of millions of objects); the one *asymptotic* part is external-memory / cache complexity — a document-order scan of a contiguous store costs Θ(n/B) cache-line transfers versus up to Θ(n) for a *scattered* tree (Aggarwal–Vitter 1988; Frigo et al. 1999), and only for sequential access.

**Choose by regime:** stream / low-memory / repeated-traversal → **XML.jl**; one-shot full-DOM → a libxml2 binder; either way, pure Julia, no C dependency. Against its own past, v0.4 is **~4.8× faster and ~12× leaner than 0.3.9** (which used ~1.4 GiB for this file) — see [`benchmarks/profile.jl`](benchmarks/profile.jl), [`benchmarks/profile_vs_039.jl`](benchmarks/profile_vs_039.jl), [`benchmarks/compare.jl`](benchmarks/compare.jl).

> **`:strict`** adds a character-range scan over text (a second O(content) pass), ~8× slower than `:structural` on text-heavy input; `:lenient` / `:structural` are unaffected.

---

_Measured 2026-06-28/29, Apple M5 (single-threaded), Julia 1.12.6; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3), XMLDict 0.4.2. Sources: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl), [`benchmarks/profile.jl`](benchmarks/profile.jl)._
