# Changelog

All notable changes to XML.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- New streaming tokenizer (`XMLTokenizer` module) for fine-grained XML token iteration.
- XPath support via `xpath(node, path)`.
- `test/test_libxml2_testcases.jl`: 243 test cases borrowed from the [libxml2](https://github.com/GNOME/libxml2) test suite covering CDATA, comments, processing instructions, attributes, namespaces, DTD internal subsets, entity references, whitespace handling, Unicode, error cases, and real-world document patterns.
- `AbstractTrees` package extension: loading both `XML` and `AbstractTrees` enables `print_tree`, `PreOrderDFS`, `Leaves`, etc. on `Node` and `LazyNode`.

### Fixed
- **Tokenizer: multi-byte UTF-8 in attribute values** — Parsing attribute values containing multi-byte UTF-8 characters (e.g., `<doc city="東京"/>`) could produce a `StringIndexError` because `attr_value()` used byte arithmetic (`ncodeunits - 1`) instead of `prevind` to strip quotes. The same issue existed in `_read_attr_value!`.
- **Tokenizer: quotes inside DTD comments** — A `"` or `'` character inside a `<!-- -->` comment within a DTD internal subset caused the tokenizer to misinterpret it as a quoted string delimiter, leading to an "Unterminated quoted string" error. The DOCTYPE body parser now correctly skips comment content.

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

[Unreleased]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.8...HEAD
[0.3.8]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/JuliaComputing/XML.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/JuliaComputing/XML.jl/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/JuliaComputing/XML.jl/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/JuliaComputing/XML.jl/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/JuliaComputing/XML.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JuliaComputing/XML.jl/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/JuliaComputing/XML.jl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/JuliaComputing/XML.jl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/JuliaComputing/XML.jl/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/JuliaComputing/XML.jl/releases/tag/v0.1.0

[#5]: https://github.com/JuliaComputing/XML.jl/pull/5
[#16]: https://github.com/JuliaComputing/XML.jl/pull/16
[#20]: https://github.com/JuliaComputing/XML.jl/pull/20
[#26]: https://github.com/JuliaComputing/XML.jl/issues/26
[#29]: https://github.com/JuliaComputing/XML.jl/pull/29
[#31]: https://github.com/JuliaComputing/XML.jl/issues/31
[#32]: https://github.com/JuliaComputing/XML.jl/pull/32
[#37]: https://github.com/JuliaComputing/XML.jl/pull/37
[#38]: https://github.com/JuliaComputing/XML.jl/pull/38
[#43]: https://github.com/JuliaComputing/XML.jl/issues/43
[#45]: https://github.com/JuliaComputing/XML.jl/pull/45
[#46]: https://github.com/JuliaComputing/XML.jl/issues/46
[#47]: https://github.com/JuliaComputing/XML.jl/pull/47
[#49]: https://github.com/JuliaComputing/XML.jl/pull/49
