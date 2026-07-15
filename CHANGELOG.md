# Changelog

All notable changes to XML.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`FlatNode` — a fourth reader: read-only columnar full-DOM** (`parse(xml, FlatNode)`,
  `read(file, FlatNode)`). The whole document is materialized once into a contiguous store of
  isbits records (zero-copy byte ranges into the retained source; text/attribute values
  entity-decoded on access), so building is fast, random access is O(1), and the GC sees a
  handful of arrays instead of one object per node — *`Node`'s read half at `Cursor`'s GC
  cost*. Extras over `Node`: O(1) `parent`, O(depth) 1-arg `depth`. By design: read-only,
  whole-store retention, 2 GiB/`typemax(Int32)` limits (use `Node` beyond). `Node(flatnode)`
  materializes a handle as a mutable `Node`; `XML.write` accepts `FlatNode` directly. Same
  well-formedness levels and error messages as the `Node` parser. **Marked experimental**
  while its usage settles in the dependent ecosystem: API details may still change in a
  0.4.x release (#82).

- **`issamenode(a, b)` — positional identity for the handle readers** (`FlatNode`: same
  store + same index; `LazyNode`: same source object + same token): "is this the same node
  of the same document", which neither `==` (structural equality) nor `===` (egal is
  content-based on immutable handles) can express (#83).

### Changed

- **`==`/`isequal`/`hash` are structural for every tree reader, cross-reader included** —
  same decoded nodetype/tag/attributes (order-insensitive)/value/children (in document
  order), recursively. `Node` already compared structurally; `LazyNode` (previously the
  egal fallback) and `FlatNode` (previously positional) now match it, and
  `Node == LazyNode == FlatNode` holds for equal content (#83). Migration: code that used
  `FlatNode` `==` as "same node" should use `issamenode`.

- **Search-based `Node` navigation raises an error on indistinguishable occurrences**:
  `parent`/`depth`/`siblings`/XPath `..` match by egal, which is content-based on parsed
  immutable nodes — in a tree with several value-identical occurrences (e.g. twin
  `<item/>` elements) they silently answered for the first match, yielding wrong depths
  and sibling lists. Unambiguous calls are unchanged. Migration: for positional navigation
  in such documents, use `FlatNode` (parent links, no ambiguity).

### Fixed

- **`hash(::Node)` restores the `==`/`hash` contract** (#55): `Node` compared structurally
  but hashed by `objectid`, so `unique`/`Dict`/`Set` misbehaved on equal nodes.

### Internal

- Source layout: the `src/XML.jl` monolith (1409 lines) is split into dedicated files —
  `escape.jl`, `node.jl`, `write.jl`, `parse.jl`, `dtd.jl` — alongside the existing
  `XMLTokenizer.jl`/`lazynode.jl`/`cursor.jl`/`xpath.jl`. Pure moves, no behavior change;
  `src/XML.jl` is now the commented include manifest.

## [0.4.1] - 2026-07-05

### Added

- `eachelement(node)` / `elements(node)` — element-only child iteration for `Node` and
  `LazyNode`, skipping the whitespace `Text` nodes that v0.4 preserves on pretty-printed
  documents (and any other non-element node). The explicit idiom for the common
  "iterate the child elements" loop ([#78](https://github.com/JuliaData/XML.jl/issues/78)).

## [0.4.0] - 2026-07-03

> **Upgrading from 0.3.x?** See the standalone [v0.4 migration guide](MIGRATING_TO_v0.4.md).

### Added
- New streaming tokenizer (`XMLTokenizer` module) for fine-grained XML token iteration.
- Pull/cursor streaming API — `Cursor` with `next!`, `for_each_child` / `@for_each_child`,
  `skip_element!`, and `eof` for forward, allocation-light traversal of large documents ([#8], [#61]).
- XPath support via `xpath(node, path)` — an experimental subset of XPath 1.0 ([#30]).
- Configurable well-formedness: `parse`/`read` accept `wellformed = :lenient | :structural | :strict`
  (default `:structural`).
- `get(node, key, default)` accessor, matching `getindex` ([#50]).
- `test/test_libxml2_testcases.jl`: 243 test cases borrowed from the [libxml2](https://github.com/GNOME/libxml2) test suite.
- `AbstractTrees` package extension (`print_tree`, `PreOrderDFS`, `Leaves`, … on `Node` and `LazyNode`).

### Changed
- **`Node` is now parametric `Node{S}`** (storage type `S`, typically `String` or `SubString{String}`)
  and is no longer a subtype of `AbstractXMLNode`. `::Node` annotations continue to work.
- **A `Node`'s `attributes` field is now a `Vector{Pair{S,S}}`** (was `OrderedDict{String,String}`).
  Use the `attributes(node)` accessor — which returns an ordered `Attributes <: AbstractDict`, or
  `nothing` — instead of indexing the field directly.
- **`LazyNode` is now an immutable `LazyNode{S}`** constructed with `parse(x, LazyNode)` /
  `read(file, LazyNode)`; the `.raw` field is removed and accessors return `SubString` views.
- **`XML.write` now escapes text and attribute values automatically**, and `parse`/`read` unescape
  into values — so `value(node)` returns decoded text (`&`, not `&amp;`). Round-trips are preserved
  because `write` re-escapes.
- **Duplicate attribute names now raise an error** during parsing.
- **`parse`/`read` reject malformed documents by default** (`wellformed = :structural`): multiple
  root elements, a document with no root element, non-whitespace text outside the root, empty/invalid
  element names, a literal `<` in an attribute value, and a misplaced/duplicate/nested DOCTYPE or XML
  declaration. `:strict` additionally rejects `--` (or a trailing `-`) in comments, empty/invalid PI
  targets, and characters — numeric references *and* raw literal characters — outside the XML §2.2
  `Char` range. Pass `wellformed = :lenient` to restore the previous permissive behavior; note that a
  standalone DTD file or a prolog-only fragment (no root element) now needs `:lenient`.
- **`Node` constructors validate names and content.** Element/PI names must be valid XML names, and
  `Comment`/`CData`/`ProcessingInstruction` content may not contain its own close delimiter (`-->`,
  `]]>`, `?>`), which would otherwise split the node on write. (Content is not otherwise validated —
  e.g. a `Comment` whose text contains `--` is constructed as-is and is rejected only on re-parse at
  `:strict`.)
- **`escape` is no longer idempotent** — every `&` is escaped, so `escape("&amp;") == "&amp;amp;"`;
  call it only on raw, unescaped text ([#52]).
- **`read` no longer memory-maps** the input file.
- **Minimum Julia version is now 1.10.**

### Deprecated
- `simplevalue` — already a deprecated alias of `simple_value` *before* 0.4 — is **no longer exported** (it stays
  reachable as `XML.simplevalue`, still warning). Use `simple_value`. *(Not a new 0.4 deprecation: the rename to the
  snake_case `simple_value`, matching `is_simple` / `is_simple_value`, predates this release; 0.4 only un-exports the
  old alias.)*

### Removed
- **`XML.Raw`** and the Raw/LazyNode streaming internals — use `parse(x, Node)` / `read(file, Node)`
  for an in-memory tree, or the new `Cursor` API for streaming.
- **`next` / `prev`** (LazyNode traversal), and **`prev!`** (the 0.3.x in-place `LazyNode` advance) —
  parse to a `Node` and use `children` / integer indexing, or the `Cursor` API. (`next!` still exists
  but now advances a `Cursor`, not a `LazyNode`; there is no `prev!` — `Cursor` is forward-only.)
- **Single-argument `parent(node)` / `depth(node)`** — use `parent(child, root)` / `depth(child, root)`.
- **`nodes_equal(a, b)`** — use `a == b`.
- **`escape!` / `unescape!`** — escaping/unescaping now happens automatically in `write` / `parse`.
- **`DTDBody`** — use `parse_dtd` or the `DTD` node.

  (Calling a removed function throws an error whose message names the replacement; `DTDBody` is
  removed outright and raises `UndefVarError`. These removals are all consequences of the v0.4 internals
  rewrite ([#54]); none has a dedicated issue to link individually.)

### Fixed
- **Tokenizer: multi-byte UTF-8 in attribute values** — values like `<doc city="東京"/>` no longer
  raise `StringIndexError` (`attr_value()` used byte arithmetic instead of `prevind`).
- **Tokenizer: quotes inside DTD comments** — a `"`/`'` inside a `<!-- -->` comment in a DTD internal
  subset no longer triggers an "Unterminated quoted string" error.
- Numeric character references are now escaped/unescaped correctly ([#17]).
- `unescape` no longer double-unescapes; each reference is processed exactly once ([#53]). It is now
  single-pass, so a numeric reference resolving to `&` is never re-scanned as a named entity —
  `unescape("&#38;amp;")` is `"&amp;"`, not `"&"`.
- A leading U+FEFF byte-order-mark character in an in-memory string is now stripped by
  `parse(_, LazyNode)` and `Cursor` as well as `parse(_, Node)`, so all three readers agree.
- A truncated comment/CDATA/PI/DOCTYPE at end of input raises a clear "unterminated …" error instead
  of being silently accepted (`Node`) or crashing `value()` (`LazyNode`/`Cursor`).
- Odd-length UTF-16 input that begins with a BOM raises a clear error instead of an opaque
  `reinterpret` failure.
- Processing-instruction content keeps its trailing whitespace on round-trip (only the leading
  separator after the target is dropped, per §2.6).
- `parse_dtd` reports a clear error on parameter-entity references (`%name;`) instead of an opaque
  internal error.
- XPath: unsupported axis syntax (`child::`, `descendant::`, …) now raises instead of silently
  returning the wrong result; dead scaffolding in `xpath` was removed.

## [0.3.9] - 2026-06-20

First release since XML.jl moved to [JuliaData](https://github.com/JuliaData/XML.jl) (transferred from JuliaComputing).

### Added
- `next!` and `prev!` for in-place, zero-allocation forward/backward traversal of `LazyNode` ([#59]).

### Fixed
- CDATA sections are now read and written with the spec-correct `<![CDATA[ … ]]>` delimiter.
  The previous `<![CData[` spelling is invalid XML and did not interoperate with other parsers ([#56]).
- `escape` now accepts any `AbstractString` (e.g. `SubString`), not only `String` ([#60]).

### Changed
- Relaxed the OrderedCollections.jl compat bound to include v2 ([#64]).

## [0.3.8]

### Fixed
- `XML.write` now respects `xml:space="preserve"` and suppresses indentation for elements with this attribute ([#49]).

## [0.3.7]

### Fixed
- Resolved remaining issues from [#45] and fixed [#46] (whitespace preservation edge cases) ([#47]).

## [0.3.6]

### Added
- `XML.write` respects `xml:space="preserve"` on elements, suppressing automatic indentation ([#45]).

### Fixed
- `String` type ambiguity on Julia nightly resolved ([#38]).

## [0.3.5]

### Fixed
- `depth` and `parent` functions corrected to work properly with the DOM tree API ([#37]).
- `escape` updated to no longer be idempotent — every `&` is now escaped, matching spec behavior ([#32], addressing [#31]).
- `pushfirst!` support added for `Node` children ([#29]).

## [0.3.4]

### Fixed
- Fixed [#26].
- CI updated to use `julia-actions/cache@v4` and `lts` Julia version.

## [0.3.3]

### Added
- `h` constructor for concise element creation (e.g., `h.div("hello"; class="main")`).

### Fixed
- Path definition error in README example ([#20]).

## [0.3.2]

### Fixed
- Minor typos.

## [0.3.1]

### Added
- Julia 1.6 compatibility ([#16]).

### Changed
- Smarter escaping logic.

## [0.3.0]

### Changed
- Attribute internal representation changed from `Dict` to `OrderedDict` (later reverted to `Vector{Pair}`).

## [0.2.3]

### Fixed
- Parse method fix.

## [0.2.2]

### Added
- DTD parsing via `parse_dtd`.
- `is_simple` and `simple_value` exports.
- `setindex!` methods for modifying attributes.
- `unescape` function.

### Fixed
- DOCTYPE parsing made case-insensitive.

## [0.2.1]

### Fixed
- Write output fixes.

## [0.2.0]

### Changed
- Major rewrite: introduced `NodeType` enum, `Node{S}` parametric struct, callable `NodeType` constructors, and `XML.write`.
- Processing instruction support.
- Benchmarks added.

## [0.1.3]

### Changed
- Improved print output for `AbstractXMLNode`.

## [0.1.2]

### Added
- AbstractTrees 0.4 compatibility ([#5]).

## [0.1.1]

### Added
- `Node` implementation with `print_tree`.
- Color output in REPL display.
- Stopped stripping whitespace from text nodes.

## [0.1.0]

- Initial release.

[Unreleased]: https://github.com/JuliaData/XML.jl/compare/v0.3.9...HEAD
[0.3.9]: https://github.com/JuliaData/XML.jl/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/JuliaData/XML.jl/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/JuliaData/XML.jl/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/JuliaData/XML.jl/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/JuliaData/XML.jl/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/JuliaData/XML.jl/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/JuliaData/XML.jl/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/JuliaData/XML.jl/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/JuliaData/XML.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/JuliaData/XML.jl/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/JuliaData/XML.jl/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/JuliaData/XML.jl/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/JuliaData/XML.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JuliaData/XML.jl/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/JuliaData/XML.jl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/JuliaData/XML.jl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/JuliaData/XML.jl/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/JuliaData/XML.jl/releases/tag/v0.1.0

[#5]: https://github.com/JuliaData/XML.jl/pull/5
[#16]: https://github.com/JuliaData/XML.jl/pull/16
[#20]: https://github.com/JuliaData/XML.jl/pull/20
[#26]: https://github.com/JuliaData/XML.jl/issues/26
[#29]: https://github.com/JuliaData/XML.jl/pull/29
[#31]: https://github.com/JuliaData/XML.jl/issues/31
[#32]: https://github.com/JuliaData/XML.jl/pull/32
[#37]: https://github.com/JuliaData/XML.jl/pull/37
[#38]: https://github.com/JuliaData/XML.jl/pull/38
[#43]: https://github.com/JuliaData/XML.jl/issues/43
[#45]: https://github.com/JuliaData/XML.jl/pull/45
[#46]: https://github.com/JuliaData/XML.jl/issues/46
[#47]: https://github.com/JuliaData/XML.jl/pull/47
[#49]: https://github.com/JuliaData/XML.jl/pull/49
[#56]: https://github.com/JuliaData/XML.jl/pull/56
[#59]: https://github.com/JuliaData/XML.jl/pull/59
[#60]: https://github.com/JuliaData/XML.jl/pull/60
[#64]: https://github.com/JuliaData/XML.jl/pull/64
[#8]: https://github.com/JuliaData/XML.jl/issues/8
[#17]: https://github.com/JuliaData/XML.jl/issues/17
[#30]: https://github.com/JuliaData/XML.jl/issues/30
[#50]: https://github.com/JuliaData/XML.jl/issues/50
[#52]: https://github.com/JuliaData/XML.jl/issues/52
[#53]: https://github.com/JuliaData/XML.jl/issues/53
[#54]: https://github.com/JuliaData/XML.jl/pull/54
[#61]: https://github.com/JuliaData/XML.jl/issues/61
