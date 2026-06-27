# Changelog

All notable changes to XML.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **`parse`/`read` reject malformed documents by default** (`wellformed = :structural`): multiple root
  elements, non-whitespace text outside the root, and empty/invalid names. Pass `wellformed = :lenient`
  to restore the previous permissive behavior.
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
- **`next` / `prev`** (LazyNode traversal) — parse to a `Node` and use `children` / integer indexing,
  or the `Cursor` API (`next!`).
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
- `unescape` no longer double-unescapes; each reference is processed exactly once ([#53]).

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
