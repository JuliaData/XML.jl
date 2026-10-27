[![CI](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml) [![codecov](https://codecov.io/gh/JuliaData/XML.jl/graph/badge.svg)](https://codecov.io/gh/JuliaData/XML.jl)

<h1 align="center">XML.jl</h1>

<p align="center">Read and write XML in pure Julia.</p>

<br>

> **Upgrading from XML.jl 0.3 to 0.4?** See the [migration guide](MIGRATING_TO_v0.4.md).

## Quickstart

```julia
using XML

filename = joinpath(dirname(pathof(XML)), "..", "test", "data", "books.xml")

doc = read(filename, Node)
# Document (4 children)

children(doc)
# 4-element Vector{Node{String}}:
#  Declaration <?xml version="1.0"?>
#  Text "\n"
#  Element <catalog> (25 children)
#  Text "\n"
```

The `Text "\n"` children are real: whitespace between elements is part of the document, and XML.jl 0.4 keeps it (0.3 dropped it — see the [migration guide](MIGRATING_TO_v0.4.md)). Use `elements` (or the lazy iterator `eachelement`) when you want the child *elements* only:

```julia
catalog = only(elements(doc))  # the root element
# Element <catalog> (25 children)

elements(catalog)[2]  # second <book> element
# Element <book id="bk102"> (13 children)
```

<br>

## Choosing a reader

XML.jl provides four readers behind one set of accessors (`nodetype`, `tag`, `attributes`,
`value`, `children`, `eachelement`, …). Pick by what you do with the document:

| Reader | Model | DOM materialized? | Revisit a node | Mutable | GC cost |
|---|---|---|---|---|---|
| `Cursor` | pull stream (StAX-like) | no: only the source and the current position are kept | impossible (forward-only) | — | ~0 |
| `LazyNode` | lazy view | no: only the source is kept; handles are made on each access | re-decode per visit | no | ~0 |
| `FlatNode` *(experimental)* | flat read-only DOM | yes, one record per node in a few arrays | O(1), built once | no | ~0 |
| `Node` | DOM of objects | yes, Julia objects (several per node) | O(1), built once | **yes** | high |

[READERS.md](READERS.md) draws what `Node`, `FlatNode` and `LazyNode` keep in memory for a small document.

Rules of thumb:

- one forward pass → `Cursor` (fastest scan, ~zero allocation; a document with declarations to apply is copied once)
- extract a little from a large document → `LazyNode` (opening copies nothing unless the document has declarations to apply, then a cost per node touched)
- read-heavy full document, repeated traversals → `FlatNode` (the random-access read API of `Node` at almost none of its GC cost: fastest build and walk, O(1) revisits)
- build or edit documents → `Node`

`FlatNode` and `LazyNode` retain the source string as long as any handle lives. Measured numbers: see [Performance by access pattern](#performance-by-access-pattern).

`Node` and `FlatNode` check that the document is well-formed, to the level the `wellformed` keyword sets; `Cursor` and `LazyNode` check only the rules on entities. See [Well-formedness and validation checks](#well-formedness-and-validation-checks).

<br>

## `Node` Interface

Every node in the XML DOM is represented by `Node`, a single type parametrized on its string storage.

```
nodetype(node)      -> XML.NodeType (an enum)
tag(node)           -> String or Nothing
attributes(node)    -> XML.Attributes{String} or Nothing
value(node)         -> String or Nothing
children(node)      -> Vector{Node}
is_simple(node)     -> Bool (e.g. <tag>text</tag>)
simple_value(node)  -> e.g. "text" from <tag>text</tag>
```

Indexing follows one rule across the tree readers (`Node`, `LazyNode`, `FlatNode`): the
key's type selects the axis. An `Int` indexes the child sequence (`node[2]`, `node[end]`),
`:` takes it whole (`node[:]`), and a `String` looks up the attribute map (`node["id"]`,
`KeyError` on a miss) — with `get(node, "id", default)` as the default-on-a-miss variant,
and `haskey`/`keys` alongside. `Cursor` supports the attribute forms on its current node.

<br>

### `NodeType`

Each item in an XML DOM is classified by its `NodeType`:

| NodeType | XML Representation | Constructor |
|----------|--------------------|-------------|
| `Document` | An entire document | `Document(children...)` |
| `DTD` | `<!DOCTYPE ...>` | `DTD(...)` |
| `Declaration` | `<?xml attributes... ?>` | `Declaration(; attrs...)` |
| `ProcessingInstruction` | `<?tag attributes... ?>` | `ProcessingInstruction(tag; attrs...)` |
| `Comment` | `<!-- text -->` | `Comment(text)` |
| `CData` | `<![CDATA[text]]>` | `CData(text)` |
| `Element` | `<tag attrs...> children... </tag>` | `Element(tag, children...; attrs...)` |
| `Text` | the `text` part of `<tag>text</tag>` | `XML.Text(text)` |

After `using XML`, write `XML.Text`: `Base` also exports a `Text`, so the bare name is ambiguous.

<br>

### Mutation

```julia
push!(parent, child)   # Add a child
parent[2] = child      # Replace a child
node["key"] = "value"  # Add/change an attribute
node["key"]            # Get an attribute
```

<br>

### Tree Navigation

```julia
depth(child, root)      # Depth of child relative to root
parent(child, root)     # Parent of child within root's tree
siblings(child, root)   # Siblings of child within root's tree
```

<br>

### Writing Elements with `XML.h`

Similar to [Cobweb.jl](https://github.com/JuliaComputing/Cobweb.jl#-creating-nodes-with-cobwebh), `XML.h` enables you to write elements with a simpler syntax:

```julia
using XML: h

node = h.parent(
    h.child("first child content", id="id1"),
    h.child("second child content", id="id2")
)
# Element <parent> (2 children)

print(XML.write(node))
# <parent>
#   <child id="id1">first child content</child>
#   <child id="id2">second child content</child>
# </parent>
```

<br>

## Reading

Every reader shares the same entry points — the reader is the second argument:

```julia
read(filename, Node)     # or LazyNode, FlatNode, Cursor
parse(str, Node)         # or LazyNode, FlatNode, Cursor
```

`Cursor` can also be constructed directly from any `AbstractString`: `Cursor(str)`.

### Well-formedness and validation checks

> [!WARNING]
> XML.jl is not a [validating processor](https://www.w3.org/TR/xml/#proc-types): it never checks a document against its DTD.

`Node` and `FlatNode` check that a document is well-formed, at three levels set by their `wellformed` keyword: `:lenient`, `:structural`, the default, and `:strict`. `Cursor` and `LazyNode` take no keyword: they check only the rules on entities, and accept mismatched tags.

```julia
parse("<a/><b/>", Node)                         # ERROR: not well-formed: multiple root elements (found 2)
parse("<a/><b/>", Node; wellformed = :lenient)  # Document (2 children)
```

[WELL-FORMEDNESS.md](WELL-FORMEDNESS.md) details what each level rejects, what validation would add, and when an undeclared entity is an error.

<br>

## Writing

```julia
XML.write(filename::String, node)  # write to file
XML.write(io::IO, node)            # write to stream
XML.write(node)                    # return String
```

`XML.write` respects `xml:space="preserve"` on elements, suppressing automatic indentation — whitespace between child elements is written verbatim instead of being reformatted:

```julia
with    = parse("<msg xml:space=\"preserve\"><b>A</b>   <b>B</b></msg>", Node)
without = parse("<msg><b>A</b>   <b>B</b></msg>", Node)

print(XML.write(only(elements(with))))    # byte-identical round-trip
# <msg xml:space="preserve"><b>A</b>   <b>B</b></msg>

print(XML.write(only(elements(without)))) # pretty-printed — the three spaces are gone
# <msg>
#   <b>A</b>
#   <b>B</b>
# </msg>
```

`XML.write` accepts `Node`, `LazyNode` (zero-copy of the original source; `normalize=true` re-parses and pretty-prints) and `FlatNode` (materializes through `Node` first). *Building* and *editing* documents is `Node`-only — the other readers are read-only.

<br>

## XPath

Query nodes using a subset of XPath 1.0 via `xpath(node, path)`:

```julia
doc = parse("""
<root>
  <a id="1"><b>hello</b></a>
  <a id="2"><b>world</b></a>
</root>
""", Node)

root = doc[1]   # the <root> element (doc[end] would be the trailing-whitespace Text node)

xpath(root, "//b")           # All <b> descendants
xpath(root, "a[@id='2']/b")  # <b> inside <a id="2">
xpath(root, "a[1]")          # First <a> child
xpath(root, "//b/text()")    # Text nodes inside all <b>s
```

### Supported syntax

| Expression | Description |
|------------|-------------|
| `/` | Root / path separator |
| `tag` | Child element by name |
| `*` | Any child element |
| `//` | Descendant-or-self (recursive) |
| `.` | Current node |
| `..` | Parent node |
| `[n]` | Positional predicate (1-based) |
| `[@attr]` | Has-attribute predicate |
| `[@attr='v']` | Attribute-value predicate |
| `text()` | Text node children |
| `node()` | All node children |
| `@attr` | Attribute value (as a `Text` node) |

Names follow XML's Name rule, in any script: `//é`, `//@ü` and `//漢字` are all valid queries.

White space between the parts of an expression, predicates included, is XML's: space, tab, line feed and carriage return.

<br>

## `Cursor`

The forward, StAX-style pull reader: one mutable cursor walks the document in document order, with no tree and one tokenizing scan. It allocates almost nothing, except one copy of a document that has declarations to apply. Advance with `next!`; read the current position with the usual accessors (`nodetype`, `tag`, `attributes`, `value`, `depth`, `is_simple`, `simple_value`):

```julia
cur = Cursor(xml_string)
while next!(cur) !== nothing
    nodetype(cur) === Element && tag(cur) == "book" && println(attributes(cur))
end
```

From a file or stream: `read(filename, Cursor)` / `read(io, Cursor)`, with the same byte-level BOM normalization as the tree readers (UTF-8 BOM strip, UTF-16 transcoding). The `Cursor(str)` constructor also accepts any `AbstractString` directly, including a `StringView` over `Mmap` for files too large for the heap (same recipe as under `LazyNode` below).

Two structured helpers carry the depth bookkeeping for you: `for_each_child(f, cur)` applies `f` to each *immediate* child of the current node (nestable — composing calls gives a full depth-first walk), and `skip_element!(cur)` jumps past the current element's entire subtree in one byte-level scan — the cheap way to classify nodes without tokenizing their contents. `@for_each_child` is the inlined-body macro form for hot extraction loops. To walk just a subtree, take the snapshot described below and cross back with `Cursor(snapshot)`, which accepts the `LazyNode` it gives you; `Cursor(data, startpos)`, the one entry that takes a byte offset from the caller, is deprecated and removed in v0.5.

A `Cursor` is one object that *mutates* as it advances: every variable referring to it sees its current position, so read what you need while the loop is on the node. To keep a node beyond further `next!` calls, take an immutable snapshot of the position with `LazyNode(cur)` — the accumulate-while-scanning idiom: `push!(found, LazyNode(cur))` keeps each hit, where `push!(found, cur)` would collect many references to one moved object. (XLSX.jl v0.12 uses exactly this snapshot to hold on to `<sheetData>` before `skip_element!` jumps past it.)

<br>

## `LazyNode`

For read-only access without building a full DOM tree, use `LazyNode`. It stores only a reference to the source string and re-tokenizes on demand, using significantly less memory:

```julia
doc = parse(xml_string, LazyNode)
doc = read("file.xml", LazyNode)
```

`LazyNode` supports the same read-only interface as `Node`: `nodetype`, `tag`, `attributes`, `value`, `children`, `is_simple`, `simple_value`, plus integer and string indexing.

`LazyNode` is for *partial* reads only:

- Opening builds nothing and reads only the prolog: line ends are normalized value by value, as each value is read (see [Line ends](#line-ends)). A source whose internal subset declares something to apply is rewritten, as described [below](#memory-mapped-files).
- A traversal costs only the bytes it steps over: descending to a target is O(bytes before it).
- Nothing is cached, so repeated visits cost again.

It is unbeatable for descents and kilobyte-scale documents. For whole-tree walks (129 ms against ~29/~68 ms build + walk on the 14 MB document below) and repeated queries, build `FlatNode` or `Node` instead: see [Performance by access pattern](#performance-by-access-pattern).

For streaming and high-throughput workloads, several extra accessors avoid materializing intermediate collections:

```julia
sourcetext(n)                # zero-copy SubString view of the node's raw source bytes
sourcespan(n)                # where that text lives: a range of valid character indices
splicetext(n, repl)          # the document text with this node's text replaced ("" default)
eachchildnode(n)             # lazy iterator over children — no Vector allocation
children!(buf, n)            # collect children into a reusable buffer
eachattribute(n)             # lazy iterator over attribute name=>value pairs
is_simple_value(n)           # combined is_simple + simple_value (one tokenizer pass)
get(n, key, default)         # single-attribute read without building Attributes
XML.write(n)                 # zero-copy: returns node's original source text
XML.write(n; normalize=true) # re-parse + pretty-print, collapses source whitespace
```

### Line ends

XML 1.0 asks a reader to turn each CR LF pair, and each lone CR, into a line feed (§2.11). `Cursor` and `LazyNode` do it value by value, as each value is read, so they never copy a document for its line ends:

- a value is the same whatever the line ends of the file, and is normalized only when you ask for it;
- `sourcetext` and `sourcespan` refer to the bytes of the string you passed, CRs included;
- a document that the declarations of its DOCTYPE change is read from a rewritten copy, to which `sourcetext` and `sourcespan` then refer (see [String types and DOCTYPE declarations](#string-types-and-doctype-declarations)).

`Node` and `FlatNode` normalize the line ends once, at the entry, in a copy of a document that holds a CR. `sourcetext`, `sourcespan` and `splicetext` on a `FlatNode` refer to that copy, whose lines end in LF: to edit a file and keep its line ends, read it with `LazyNode`.

### Memory-mapped files

Memory mapping is optional — `LazyNode`'s laziness is about *node materialization*, and it is just as useful on in-memory strings. For files too large to read into heap memory, combine it with a `StringView` over `Mmap`:

```julia
using XML, Mmap, StringViews

doc = open("very_large.xml") do io
    sv = StringView(Mmap.mmap(io))
    parse(sv, LazyNode)
end
```

From Julia 1.14, `StringView` is part of Base, so `using XML, Mmap` is enough; on earlier versions it comes from StringViews.jl, as above.

The reader keeps the string type it is given: the document is walked through the mapping instead of being copied into the heap, and accessors return views into the mapped bytes. `Node` and `FlatNode` do not: they copy the document into a `String` before they parse it, so a mapping saves them no memory.

Opening costs one probe of the prolog, about 25 ns on a mapped 14 MB document, LF or CR LF alike:

- the document is neither scanned nor rewritten for its line ends;
- the line-end normalization the specification requires happens on each value as it is read;
- a file written with CR LF or a lone CR thus copies only the values you actually ask for, and only those that carry a line end.

The exception is a document that the declarations of its DOCTYPE change: the entities it uses, the default attribute values it receives, the spaces of the attributes declared with a type other than CDATA (XML 1.0 §4.4.2, §3.3.2, §3.3.3). The reader then reads a copy of it in the heap, with these changes made (see [String types and DOCTYPE declarations](#string-types-and-doctype-declarations)).

> [!WARNING]
> This is a limitation for a file too large for memory. XML.jl does not refuse such a document, but the rewritten copy can exceed the physical memory. The system then either swaps memory to disk, which can make the reading very long, or refuses the allocation.

`sourcetext` is the one accessor that shows the file's own bytes. It is a zero-copy view of the document the reader holds, which for a mapped file that needs no rewrite is the file itself. See [Memory-mapped sources](PERFORMANCE-v0.4.md#memory-mapped-sources) for the measured figures.

### String types and DOCTYPE declarations

`Node` and `FlatNode` convert their source to a `String` before they read it, whatever its string type. They thus apply the declarations of its DOCTYPE to a document of any string type.

`Cursor` and `LazyNode` keep the string type they are given. When the declarations of its DOCTYPE change a document, they read a copy of it with these changes made, of that same string type. The changes are the entities the document uses, the default attribute values it receives, and the spaces removed from the attributes declared with a type other than CDATA. The copy can be made for:

- a `String`, or a `SubString{String}` such as `view(str, i:j)`;
- a `StringView` over a byte vector `v` (a `Vector{UInt8}`), as for a memory-mapped file, or over a slice `view(v, i:j)` of it, written without a step.

On any other string type, such a document raises an `ArgumentError`. Two examples are a `LazyString`, and a `StringView` over a view of `v` written with a step, such as `view(v, i:2:j)` or `view(v, i:1:j)`. Read such a document with `Node` or `FlatNode`, or pass `String(s)` to `Cursor` or `LazyNode`. A document that its DOCTYPE does not change is read from any string type.

<br>

## `FlatNode` *(experimental)*

The whole document parsed once into a contiguous columnar store — the random-access read API of `Node` at almost none of its GC cost: fast build, O(1) random access and O(1) `parent`, and the garbage collector sees a handful of arrays instead of one object per node.

```julia
doc = parse(xml_string, FlatNode)     # or read("file.xml", FlatNode)
root = only(eachelement(doc))
for el in eachelement(root)
    tag(el), attributes(el), value(el)
end
```

Same read-only accessor surface as the other readers, including `sourcetext(node)` — the zero-copy `SubString` of a node's original source text — its positional counterpart `sourcespan(node)`, the range of valid character indices that text occupies (O(1) here, from the stored spans), and `splicetext(node, replacement)` — the document source with that text replaced; all three are available on the two readers that retain the source (`FlatNode`, `LazyNode`) and not on `Node`. By design: read-only — creating or modifying documents is `Node`'s job; any live handle retains the whole store and source string; documents are limited to 2 GiB. `Node(flatnode)` materializes a handle (and its subtree) as a mutable `Node`; `XML.write` accepts a `FlatNode` directly. Positional identity — "same node of the same document" — is `issamenode(a, b)`, defined like `sourcetext` for the two handle readers (`FlatNode`, `LazyNode`); it does not apply to `Node`, a self-contained value with no document anchor.

> **Experimental** — new in v0.4.2: API details may still change in a 0.4.x release while ecosystem usage settles. Feedback welcome on the [issue tracker](https://github.com/JuliaData/XML.jl/issues).

<br>

## Under the hood

All four readers sit on `XML.XMLTokenizer`, a zero-allocation streaming tokenizer (a token is a kind plus a byte range into the source). It is usable directly for token-level tooling — see the `XML.XMLTokenizer` module docstrings.

<br>

## AbstractTrees Integration

Loading [`AbstractTrees`](https://github.com/JuliaCollections/AbstractTrees.jl) alongside XML enables tree-walking utilities (`print_tree`, `PreOrderDFS`, `Leaves`, etc.) on both `Node` and `LazyNode`:

```julia
using XML, AbstractTrees

doc = parse("<a><b/><c><d/></c></a>", Node)
print_tree(doc)
# Document
# └─ <a>
#    ├─ <b>
#    └─ <c>
#       └─ <d>

for n in PreOrderDFS(doc)
    nodetype(n) == Element && println(tag(n))
end
```

<br>

## Performance by access pattern

One number cannot rank the readers — cost depends on what you do with the document. Same ~14 MB / 882 K-node XMark-style document as the cross-library table below (source: [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl); **lower is better**; BenchmarkTools `@benchmark` medians at default parameters):

| | build | walk every node | extract all values | DOM size in memory |
|---|--:|--:|--:|--:|
| `Cursor` | — (streams) | 20.5 ms (its one scan) | — | — (no DOM) |
| `LazyNode` | 19 ns (reads the prolog) | 129 ms (re-tokenizes) | — | — (source only) |
| `FlatNode` | 26.5 ms | 2.88 ms | 2.93 ms | 54.9 MiB |
| `Node` | 64.1 ms | 3.44 ms | 3.65 ms | 71.6 MiB |
| EzXML (libxml2) | 37.4 ms | — | — | — |

Reading the table: `Cursor`'s walk *is* its parse — one tokenizing scan, nothing retained. `LazyNode` materializes nothing, so its open reads only the prolog, without allocating. The source is rewritten once only when its internal subset declares something to apply: general entities, attribute defaults, attributes of a type other than CDATA. After that it costs per node visited. That still makes it the pick for touching a *fraction* of a large document, and, as the walk column shows, the wrong tool for visiting all of it.

`FlatNode` builds ~2.4× faster than `Node` and holds ~23% less memory. Its `parent` and `depth` are O(1), where `Node` searches from the root. Whole-tree walks are close, because `Node`'s exact-size children vectors keep its locality sharp. Pure value extraction is close too, with the flat store slightly faster: 2.93 against 3.65 ms, since a per-value `SubString` view costs two integer stores. `FlatNode` builds ~1.4× faster than even libxml2, and `Node`'s gap to the C library is materialization, not scanning (see [PERFORMANCE-v0.4.md](PERFORMANCE-v0.4.md)).

_Measured 2026-10-27, Apple M5 (single-threaded), Julia 1.13.3, EzXML 1.2.3; BenchmarkTools medians._

<br>

## Benchmarks

Source: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl). Data: `books.xml` (~4 KB) and a generated XMark-style auction document (~14 MB). The XML.jl column uses `Node` throughout — the full mutable DOM, the like-for-like counterpart of the libxml2 DOMs the C wrappers build; [Performance by access pattern](#performance-by-access-pattern) above shows how the other readers change the picture. BenchmarkTools median time, **lower is better.**

What the constructions this document lacks cost, what each `wellformed` level adds, and the entry points no table above covers are in [PERFORMANCE-v0.4.md](PERFORMANCE-v0.4.md), Tables 6 to 8.

| Benchmark | XML.jl | EzXML | LightXML | XMLDict |
|---|--:|--:|--:|--:|
| Parse, small | 13.0 µs | 11.2 µs | 11.0 µs | 124 µs |
| Parse, medium | 63.4 ms | 37.7 ms | 37.7 ms | 318 ms |
| Write, small | 4.14 µs | 5.65 µs | 57.4 µs | — |
| Write, medium | 18.2 ms | 20.6 ms | 30.7 ms | — |
| Collect tags, small | 0.345 µs | 1.06 µs | 1.76 µs | — |
| Collect tags, medium | 4.84 ms | 9.92 ms | 13.6 ms | — |

EzXML and LightXML wrap libxml2 (C): faster on raw parse, slower on in-Julia traversal.
Times include garbage collection; [PERFORMANCE](PERFORMANCE-v0.4.md) breaks each of its rows
into the stable GC-free work and the per-session GC share.

For the per-access-pattern decomposition (streaming / partial reads / full DOM / stage breakdown) and the theory behind these numbers, see [**PERFORMANCE-v0.4.md**](PERFORMANCE-v0.4.md).

_Measured 2026-10-27, Apple M5 (single-threaded), Julia 1.13.3; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3), XMLDict 0.4.2. Source: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl)._
