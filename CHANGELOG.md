# Changelog

Itemised from v0.3.9 onward; for earlier releases see the
[GitHub releases](https://github.com/JuliaData/XML.jl/releases) and git tags.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[0.3.9]: https://github.com/JuliaData/XML.jl/compare/v0.3.8...v0.3.9
[#56]: https://github.com/JuliaData/XML.jl/pull/56
[#59]: https://github.com/JuliaData/XML.jl/pull/59
[#60]: https://github.com/JuliaData/XML.jl/pull/60
[#64]: https://github.com/JuliaData/XML.jl/pull/64
