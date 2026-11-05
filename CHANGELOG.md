# Changelog

All notable changes to XML.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`string_value(node)` returns the text of an element, whatever it holds** ([#154](https://github.com/JuliaData/XML.jl/issues/154)): the text of all its `Text` and `CData` descendants, in document order, as the string-value of [XPath 1.0 §5](https://www.w3.org/TR/1999/REC-xpath-19991116/#data-model) defines it. It gives `"x y z"` for `<p>x <b>y</b> z</p>`, and `"https://example.org/a"` for `<guid isPermaLink="true">https://example.org/a</guid>`, which `simple_value` refuses for its attribute. It works on `Node`, `LazyNode` and `FlatNode`. A single text is returned as `value` returns it, so without a copy when it holds no reference and no line end to fold. A document gives the text of its elements: the line breaks between its children are not counted.

- **`write` takes `pretty = false`** ([#158](https://github.com/JuliaData/XML.jl/issues/158)), which adds and drops no white space between the nodes of a `Node`. A parsed document keeps its whitespace text, its line ends in LF as the reader gives them, and a tree built in code comes out with nothing between its nodes. The tags are written as before, so `<br />` still comes out as `<br/>`. `write` on a `FlatNode` takes it too, and so does `write` on a `LazyNode` with `normalize = true`.

### Changed

With the changes below, the same call can give another result than with v0.4.8.

- **`text()` in `xpath` also selects CDATA sections** ([#153](https://github.com/JuliaData/XML.jl/issues/153)), as [XPath 1.0 §5.7](https://www.w3.org/TR/1999/REC-xpath-19991116/#section-Text-Nodes) asks. It selected `Text` children only, so `//item/title/text()` found nothing in an RSS feed whose titles are CDATA sections. It now returns the `Text` and `CData` children in document order, as libxml2 does.

- **`:strict` refuses a name that breaks the Name rule** ([#181](https://github.com/JuliaData/XML.jl/issues/181)) of [XML 1.0 §2.3](https://www.w3.org/TR/xml/#sec-common-syn), for an element, an attribute or a processing-instruction target. It refuses `<doc 12="34"/>`: no level checked attribute names. It also refuses an element name such as `·x` or `a×b`, since only the first character of a name was checked, and any character beyond ASCII passed. The other levels keep accepting them.

## [0.4.8] - 2026-11-04

### Changed

With the changes below, the same call can give another result than with v0.4.7.

- **An unknown `wellformed` level throws an `ArgumentError`** ([#201](https://github.com/JuliaData/XML.jl/issues/201)). `parse` and `read` gave it the checks of `:structural` without notice, so a misspelled `:strict` such as `:strcit` skipped the strict checks.

- **`:strict` refuses an `&` that starts no reference** ([#202](https://github.com/JuliaData/XML.jl/issues/202)), such as `R&D` or `a & b`, and a character reference written with an uppercase `X`, such as `&#X41;`. The other levels keep accepting both, and still decode `&#X41;`.

- **`:strict` checks the pseudo-attributes of the XML declaration** ([#205](https://github.com/JuliaData/XML.jl/issues/205)) against [XML 1.0 §2.8](https://www.w3.org/TR/xml/#sec-prolog-dtd). It refuses an unknown or misplaced pseudo-attribute, such as `foo="bar"` or `encoding` before `version`, a missing `version`, and a pseudo-attribute with no white space before it. It also refuses a value that its rule does not allow, such as `version="2.0"` or `standalone="maybe"`. The other levels keep accepting them.

- **`:strict` refuses two attributes with no white space between them** ([#208](https://github.com/JuliaData/XML.jl/issues/208)), such as `<r a="1"b="2"/>`, as [XML 1.0 §3.1](https://www.w3.org/TR/xml/#sec-starttags) requires. The other levels keep accepting them.

### Fixed

- **`XML.write` writes a `Node{SubString{String}}`** ([#199](https://github.com/JuliaData/XML.jl/issues/199)) instead of throwing a `MethodError`. It keeps the entity references of these raw values, and the character references that the default `Node` decodes, as they are, and escapes the other characters as `escape` does.

- **A tag with many attributes is checked for duplicates in O(n log n) time** ([#200](https://github.com/JuliaData/XML.jl/issues/200)), not O(n²): a single tag of a few hundred kilobytes could hold `Node` or `FlatNode` for seconds. Past 32 attributes, the tag is checked once it closes, by sorting its names, so another error in the same tag may now be reported first.

## [0.4.7] - 2026-11-02

### Added

- **`XML.escape` and `XML.unescape` are public** ([#125](https://github.com/JuliaData/XML.jl/issues/125)), for code that builds XML strings itself. They stay unexported. `escape` writes a carriage return as `&#13;`, and with `attribute = true` also a tab and a line feed as `&#9;` and `&#10;`, as `XML.write` does: a reader then gives the string back as written ([#184](https://github.com/JuliaData/XML.jl/issues/184)).

- **`Cursor` has `is_simple` and `simple_value`** ([#131](https://github.com/JuliaData/XML.jl/issues/131)), like the other readers.

- **Documentation**: `WELL-FORMEDNESS.md` ([#152](https://github.com/JuliaData/XML.jl/issues/152)) says what each `wellformed` setting refuses, and `READERS.md` shows how `Node`, `FlatNode` and `LazyNode` hold a document in memory. The README, the docstrings and `MIGRATING_TO_v0.4.md` now say when opening a document copies it and what the declarations of a DOCTYPE change ([#185](https://github.com/JuliaData/XML.jl/issues/185), [#196](https://github.com/JuliaData/XML.jl/issues/196)).

- **Benchmarks and tests**: the benchmark document can now include entities, comments, CDATA sections and other constructions it lacked ([#138](https://github.com/JuliaData/XML.jl/issues/138)). The published libxml2 figures, measured while the documents built by libxml2 were never freed, and the XLSX figures, which timed no cell read, are corrected. The W3C conformance tests compare the values read with the suite's reference outputs ([#94](https://github.com/JuliaData/XML.jl/issues/94)).

### Changed

With the changes below, the same call can give another result than with v0.4.6.

- **Line ends are normalized** ([XML 1.0 §2.11](https://www.w3.org/TR/xml/#sec-line-ends), [#129](https://github.com/JuliaData/XML.jl/issues/129), [#194](https://github.com/JuliaData/XML.jl/issues/194)): every reader now reads CR LF and a lone CR as LF, in text, attribute values, comments, CDATA sections, processing instructions and the DOCTYPE. A CR written as `&#13;` still reads as CR. `Cursor` and `LazyNode` normalize each value as they read it, without copying the document: reading every value takes up to about 10 % longer than with v0.4.6, plus a copy of each value that holds a CR. `Node` and `FlatNode` normalize a copy of a document that holds a CR, so `sourcetext`, `sourcespan` and `splicetext` on a `FlatNode` give LF line ends (see [Line ends](README.md#line-ends)).

- **Entities declared in the DOCTYPE are replaced by their text** ([XML 1.0 §4.4](https://www.w3.org/TR/xml/#entproc), [#130](https://github.com/JuliaData/XML.jl/issues/130), [#188](https://github.com/JuliaData/XML.jl/issues/188)): with `<!DOCTYPE r [<!ENTITY e "x">]><r>&e;</r>`, the text of `r` is now `x` in every reader, where v0.4.6 kept `&e;`. An entity whose text holds markup produces elements, and references inside attribute values are replaced too. An entity that refers to itself, or entities nested more than 40 levels deep, raise an error. So do declarations that make the document read more than 8 MiB, or grow past 64 MiB, beyond 100 times its size (see [`WELL-FORMEDNESS.md`](WELL-FORMEDNESS.md#what-the-declarations-may-cost)).

- **Default attribute values declared in the DOCTYPE are applied** ([XML 1.0 §3.3.2](https://www.w3.org/TR/xml/#sec-attr-defaults), [#131](https://github.com/JuliaData/XML.jl/issues/131)): with `<!DOCTYPE d [<!ATTLIST d lang CDATA "en">]><d/>`, the element `d` now has `lang="en"` in every reader, where v0.4.6 ignored the declaration. `attributes` thus returns additional attributes that v0.4.6 missed, such as this `lang`. `is_simple` returns `false` for an element that receives a default value, so `simple_value` raises on it. The value of an attribute declared with a type other than `CDATA`, such as `NMTOKENS`, loses its leading and trailing spaces, and runs of spaces become one: `t="  a   b "` reads as `"a b"` ([XML 1.0 §3.3.3](https://www.w3.org/TR/xml/#AVNormalize)).

- **`Cursor` and `LazyNode` make these changes only on the string types listed in their docstrings** ([#185](https://github.com/JuliaData/XML.jl/issues/185)), unlike `Node` and `FlatNode`: on another string type, a document that its DOCTYPE declarations change raises an `ArgumentError`, where v0.4.6 made no change.

- **`parse(s, LazyNode)` and `parse(s, Cursor)` keep the string type of their source** ([#134](https://github.com/JuliaData/XML.jl/issues/134), [#166](https://github.com/JuliaData/XML.jl/issues/166), [#187](https://github.com/JuliaData/XML.jl/issues/187), [#194](https://github.com/JuliaData/XML.jl/issues/194)): `parse(view(str, i:j), LazyNode)` now returns a `LazyNode{SubString{String}}`, where v0.4.6 copied the source and returned a `LazyNode{String}`. They copy only a document that the declarations of its DOCTYPE change.

- **`wellformed = :strict` refuses more documents** ([#130](https://github.com/JuliaData/XML.jl/issues/130), [#131](https://github.com/JuliaData/XML.jl/issues/131), [#182](https://github.com/JuliaData/XML.jl/issues/182)), as XML 1.0 requires:
  - a reference to an entity that the document does not declare, unless the declaration may be in a part of the DTD that XML.jl does not read ([XML 1.0 §4.1](https://www.w3.org/TR/xml/#sec-references));
  - a reference to an unparsed entity (declared with `NDATA`), or to an external entity (declared with `SYSTEM` or `PUBLIC`) inside an attribute value;
  - a `%name;` reference inside a declaration ([XML 1.0 §2.8](https://www.w3.org/TR/xml/#sec-prolog-dtd));
  - a default value that holds `<`, or that names an external or unparsed entity, or an entity declared only after it;
  - an `ATTLIST` declaration that cannot be read, such as one with a missing space.

  With the default `:structural`, these documents are still read, and their references stay as written. Of the 1257 not-well-formed documents of the W3C suite, `:strict` refuses 515, against 367 with v0.4.6.

### Deprecated

- **`Cursor(data, startpos)`**, to be removed in v0.5. To walk a subtree, start from a snapshot: `Cursor(LazyNode(cursor))`.

- **`XML.XMLTokenizer._skip_element_raw`**, to be removed in v0.5. To find where an element ends, call `sourcespan` or `splicetext` on its `LazyNode`.

### Removed

- **`XML.parse_dtd`** and the types it returned (`ParsedDTD`, `ElementDecl`, `AttDecl`, `NotationDecl`). The name was neither exported nor declared public, and no registered package called it; the readers now apply the declarations of the DOCTYPE themselves. Calling it raises an error that points to the `DTD` node.

### Fixed

- **Julia 1.14** ([#175](https://github.com/JuliaData/XML.jl/issues/175)): reading no longer calls a `SubString` constructor that Julia 1.14 deprecates, which made XML.jl's own tests about 40 times slower. A `StringView` source works without loading StringViews.jl, and `wellformed = :strict` still refuses overlong UTF-8 sequences, such as `\xc1\x81`, which Julia 1.14 decodes as `A`.

- **`Cursor` on Julia 1.11.0 to 1.11.4 under `--check-bounds=yes`** ([#170](https://github.com/JuliaData/XML.jl/issues/170)) could misread a document, through a compiler bug fixed in Julia 1.11.5, and XLSX.jl then failed to find `<sheetData>`. XML.jl now avoids the code that triggers the bug on these versions.

- **`using XML` no longer hides `Base.eof`** ([#156](https://github.com/JuliaData/XML.jl/issues/156)): `eof` works on cursors and on Julia streams alike.

- **XPath reads names as XML defines them** ([#180](https://github.com/JuliaData/XML.jl/issues/180), [#189](https://github.com/JuliaData/XML.jl/issues/189)): `//é`, `//@ü` or a Hindi or Thai name raised a `StringIndexError`, and `//@a.b` returned nothing. A space other than XML's four (space, tab, CR, LF) is now an error anywhere in an expression, and the error names it by its code point, such as U+00A0. `@1x` and `@:x`, which are not XPath names, are errors too.

- **`XML.write` keeps a text made only of spaces that XML does not count as white space** ([#177](https://github.com/JuliaData/XML.jl/issues/177)), such as the no-break space U+00A0: between two elements, it took such a text for indentation and dropped it.

- **A processing instruction inside the DOCTYPE no longer breaks it**: a `]` or a quote in its text ended the DOCTYPE early or raised an error.

- **`skip_element!` no longer stops inside a comment or a processing instruction that starts with `>`**, as in `<!--></a>-->` or `<?></a>?>`.

- **`sourcetext`, `sourcespan` and `splicetext` on a `LazyNode` element are faster** ([#157](https://github.com/JuliaData/XML.jl/issues/157), [#178](https://github.com/JuliaData/XML.jl/issues/178)): they find the end of the element by scanning its bytes instead of reading every tag inside it, about ten times faster on a 64 MB element. `sourcetext` no longer allocates, and `skip_element!` uses the same scan.

- **`unescape` allocates once per value** ([#141](https://github.com/JuliaData/XML.jl/issues/141), [#192](https://github.com/JuliaData/XML.jl/issues/192)), instead of four to six times for a value that holds a reference. A value it does not decode is returned as it is, in its own type.

- **`wellformed = :strict` costs less** ([#142](https://github.com/JuliaData/XML.jl/issues/142), [#143](https://github.com/JuliaData/XML.jl/issues/143)): it now allocates exactly what `:structural` does, where v0.4.6 allocated for each reference it checked, and it checks ASCII text many bytes at a time. [Table 7 of `PERFORMANCE-v0.4.md`](PERFORMANCE-v0.4.md#well-formedness-levels) gives its cost by kind of document.

## [0.4.6] - 2026-08-17

### Fixed

- **Julia 1.10 builds mis-executed downstream worksheet scans** — XLSX.jl workbook opens failed with `No sheetData node found in worksheet` ([XLSX.jl#448](https://github.com/JuliaData/XLSX.jl/issues/448)): a Julia 1.10 compilation defect triggered by v0.4.5's branchless span fallback. The 1.10 build now selects the earlier two-branch body (1.11+ builds are unchanged), and the Downstream and default-bounds CI jobs also run on LTS.

## [0.4.5] - 2026-08-13

### Added

- **GC-tuning note in PERFORMANCE-v0.4.md**: `--gcthreads=4` cuts a full collection with a
  large live `Node` tree ~2.7× on the benchmark document, at no cost to computation —
  measured guidance for applications that hold big trees.

### Changed

- **`LazyNode` iteration is allocation-light, with its shared-cursor semantics pinned**:
  the child, element, and attribute iterators hold the tokenizer's isbits state as inline
  fields — no per-call mutable tokenizer wrapper, no heap `RefValue` cursor, no boxed
  tuple per step. Pulling children through an iterator allocates nothing; creating one
  costs a single small object, elided where it never loops. Every loop over the same
  iterator object resumes where the previous one stopped — the contract downstream row
  streams (XLSX.jl) rely on, now pinned in tests. A full lazy traversal of the 14 MB
  benchmark document drops from 2.6 M allocations / 121 MiB of garbage to 273 K / 21 MiB,
  median −23 % (#118, #119, #121).

- **The `Node` build no longer allocates per-element vectors**: children and attributes
  accumulate on parse-wide scratch stacks, sliced out exact-size at each closing tag. On
  the 14 MB benchmark document: ~380 K allocations and ~22 MiB of garbage less per build,
  median build −7.5 %, retained tree 80.0 → 71.6 MiB, full walks ~1.4× faster (#107).

- **Views are span-native end to end**: tokens carry `(offset, ncodeunits)` byte spans,
  and every view — `raw`, the tag/attribute/PI accessors, `FlatNode`'s span→view
  helpers — is rebuilt by direct field construction, with no `prevind`/`nextind` walks.
  Sound because every span edge falls on an ASCII byte or EOF, hence a UTF-8 character
  boundary; `--check-bounds=yes` builds (as in `Pkg.test`) compile the checked
  reconstruction instead, selected at load time. On the 14 MB document: lex 37.4 → 23.4 ms,
  `FlatNode` extract 6.6 → 3.1 ms, and two orderings reverse — `FlatNode` builds ~1.7×
  faster than libxml2 and extracts faster than `Node`'s direct field reads — while
  pure-Julia streaming is ~2.5× faster than EzXML's `StreamReader`. Allocations
  unchanged throughout (#109, #111, #113).

- **Measurement upkeep**: every timing in PERFORMANCE-v0.4.md and the README is a
  BenchmarkTools `@benchmark` median (`benchmarks/flatnode_bench.jl` rewritten
  accordingly); the cross-library suite bounds its own C heap (per-sample `finalize`
  teardown, between-cell collection) so a full run no longer pages the machine;
  sub-millisecond README rows are quoted in microseconds (#107, #110); and the
  decomposed pipeline reports the absolute allocation count of every cell and gains a
  per-reader whole-tree traversal section — a per-node cost hides in a ratio but not in
  a counter (#120).

### Fixed

- **`simple_value(::FlatNode)` no longer heap-allocates on default-bounds builds** —
  32 B per call on the build users actually run, a regression the span-native rerouting
  introduced and that neither `Pkg.test` (which forces `--check-bounds=yes`) nor
  coverage CI could see. A new CI job now runs the suite on the default-bounds build
  with the allocation guards active, and the `Node` build gains an allocation ceiling
  pinning its scratch-stack contract (#122).

## [0.4.4] - 2026-07-31

### Added

- **By-key attribute access, completed across readers** — one rule: the key's type selects
  the axis (an `Int` indexes the child sequence, `:` takes it whole, a `String` looks up the
  attribute map, `get` being the default-on-a-miss variant). `FlatNode` gains
  `n["key"]`/`get`/`haskey`/`keys` (attribute-range scan, only the matched value decoded)
  plus the `n[:]`/`n[end]`/`only` child-axis forms; `Cursor` gains `getindex`/`haskey`/`keys`
  beside its existing `get`, on the current node (#100).

### Changed

- **The performance tables decompose garbage collection**: every timed row in
  PERFORMANCE-v0.4.md now reads `total (GC x)` under a `time (incl. GC)` header — the total
  is what a user lives, the GC share is the per-session draw, and their difference is the
  reproducible work time. The benchmark harnesses (`profile.jl`, `flatnode_bench.jl`) print
  the decomposition; `flatnode_bench.jl` reports the median run's own pair.

### Fixed

- **The decoded read surface is now allocation-free** on the three zero-copy readers
  (`LazyNode`, `FlatNode`, `Cursor`): `n["key"]`/`get`/`haskey`, `value`,
  `simple_value`/`is_simple_value` and `eachattribute` no longer heap-box their result on
  entity-free content — previously 32–320 B on every call, the same type-instability
  phenomenon the v0.4.3 normalization fix removed (#98): `unescape`'s union return, the
  `getindex` sentinel default, and small unions crossing non-inlined call boundaries.
  `simple_value(::LazyNode)` now runs the same single-pass token walk as
  `is_simple_value` instead of materializing `attributes` and `children`. On the 14 MB
  benchmark document, a full `Cursor` streaming pass now allocates nothing at all (was
  17 MiB) and runs ~14 % faster, and the `FlatNode` value-extraction stage drops ~30 %
  (9.3 → 6.6 ms). Allocation guards in the test suite pin every accessor at zero (#105).
- **`foreach_attr`'s docstring no longer recommends the internal tokenizer layer**
  (`XML.XMLTokenizer.raw`/`attr_value`) — a workaround from before the decoded surface
  was allocation-free, and a semantic trap: `attr_value` only strips the quotes,
  performing no character-reference resolution and no XML 1.0 §3.3.3 white-space
  normalization. The docstring now points to `eachattribute` (decoded, equally
  allocation-free) and spells out the raw-layer caveat (#104).

## [0.4.3] - 2026-07-26

### Added

- **`sourcespan(n) -> UnitRange{Int}`** on the two source-retaining readers (`LazyNode`,
  `FlatNode`): the range of *valid character indices* the node's original source text
  occupies, with the invariant `sourcetext(n) == SubString(source, sourcespan(n))` — the
  library does the `prevind` computation, so multi-byte boundaries are safe to slice and
  splice around. O(1) on `FlatNode` (answered from the stored per-record spans). For
  consumers that need a node's *position* rather than its text — verbatim excision and
  splicing without reaching into reader internals (#92).
- **`splicetext(n, replacement = "")`** on the same two readers: the document source with
  the node's own text replaced — excised entirely by default. The packaged, multi-byte-safe
  form of the `sourcespan` splice (#92).

### Changed

- **`LazyNode`'s child iterator defers each yielded element's subtree skip** until the
  next sibling is requested: a traversal that stops early only tokenizes the bytes it
  actually stepped over, making descents O(bytes before the target) — touching a 14 MB
  document's root element drops from ~35 ms to ~4 µs, a nine-node document-order descent
  from ~50 ms to ~5 µs. Full traversals do the same total work as before (#91).

### Fixed

- **Attribute values are now normalized per XML 1.0 §3.3.3** (all four readers): literal
  tab/newline/CR in an attribute value read as spaces — the CR LF pair as a single space —
  while white space written as character references (`&#9;` `&#10;` `&#13;`) still reads
  as the referenced character. Previously the raw characters came through, so a document
  with attributes wrapped across lines read differently in XML.jl than in conforming
  parsers such as libxml2. On write, attribute values now escape literal tab/newline/CR as
  character references, so values round-trip exactly (#93).

- **`parse(str, Cursor)`, `read(filename, Cursor)`, `read(io, Cursor)`** — `Cursor` gains the
  tree readers' entry points: same argument order, and the `read` forms apply the same
  byte-level BOM normalization (UTF-8 BOM strip, UTF-16 LE/BE transcoding; a BOM-less UTF-16
  file now gets the explicit `"UTF-16 without a BOM is not well-formed (XML 1.0 §4.3.3)"`
  error instead of a cryptic tokenizer one). `Cursor(str)` and `parse(Cursor, str)` are
  unchanged (#89).

## [0.4.2] - 2026-07-16

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
  default egal fallback) now matches it, the new `FlatNode` has these semantics
  from the start, and `Node == LazyNode == FlatNode` holds for equal content (#83).

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
- DTD parsing via `DTDBody`, unexported; its constructor raised an error in every release up to v0.3.9.
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

[Unreleased]: https://github.com/JuliaData/XML.jl/compare/v0.4.8...HEAD
[0.4.8]: https://github.com/JuliaData/XML.jl/compare/v0.4.7...v0.4.8
[0.4.7]: https://github.com/JuliaData/XML.jl/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/JuliaData/XML.jl/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/JuliaData/XML.jl/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/JuliaData/XML.jl/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/JuliaData/XML.jl/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/JuliaData/XML.jl/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/JuliaData/XML.jl/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JuliaData/XML.jl/compare/v0.3.9...v0.4.0
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
