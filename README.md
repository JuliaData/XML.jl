[![CI](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml) [![codecov](https://codecov.io/gh/JuliaData/XML.jl/graph/badge.svg)](https://codecov.io/gh/JuliaData/XML.jl)

<h1 align="center">XML.jl</h1>

<p align="center">Read and write XML in pure Julia.</p>

<br>

> **Upgrading from XML.jl 0.3 to 0.4?** See the [migration guide](MIGRATING_TO_v0.4.md).

# Quickstart

```julia
using XML

filename = joinpath(dirname(pathof(XML)), "..", "test", "data", "books.xml")

doc = read(filename, Node)

children(doc)
# 2-Element Vector{Node}:
#  Node Declaration <?xml version="1.0"?>
#  Node Element <catalog> (12 children)

doc[end]  # The root node
# Node Element <catalog> (12 children)

doc[end][2]  # Second child of root
# Node Element <book id="bk102"> (6 children)
```

<br>

# Choosing a reader

XML.jl ships four readers behind one set of accessors (`nodetype`, `tag`, `attributes`,
`value`, `children`, `eachelement`, …). Pick by what you do with the document:

| Reader | DOM materialized? | Revisit a node | Mutable | GC cost |
|---|---|---|---|---|
| `Cursor` | no (nothing) | impossible (forward-only) | — | ~0 |
| `LazyNode` | virtual | re-decode per visit (pay-per-traversal) | no | ~0 |
| `FlatNode` *(experimental)* | yes, compact (columnar) | O(1), paid once | no | ~0 |
| `Node` | yes, objects | O(1), paid once | **yes** | high |

Rules of thumb:

- one forward pass → `Cursor` (fastest scan, ~zero allocation)
- extract a little from a large document → `LazyNode` (opening is free; you pay per node touched)
- read-heavy full document, repeated traversals → `FlatNode` (the random-access read API of `Node` at almost none of its GC cost: fastest build and walk, O(1) revisits)
- build or edit documents → `Node`

`FlatNode` and `LazyNode` retain the source string as long as any handle lives. Measured numbers: see [Performance by access pattern](#performance-by-access-pattern).

<br>

# `Node` Interface

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

<br>

## `NodeType`

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
| `Text` | the `text` part of `<tag>text</tag>` | `Text(text)` |

<br>

## Mutation

```julia
push!(parent, child)   # Add a child
parent[2] = child      # Replace a child
node["key"] = "value"  # Add/change an attribute
node["key"]            # Get an attribute
```

<br>

## Tree Navigation

```julia
depth(child, root)      # Depth of child relative to root
parent(child, root)     # Parent of child within root's tree
siblings(child, root)   # Siblings of child within root's tree
```

<br>

## Writing Elements with `XML.h`

Similar to [Cobweb.jl](https://github.com/JuliaComputing/Cobweb.jl#-creating-nodes-with-cobwebh), `XML.h` enables you to write elements with a simpler syntax:

```julia
using XML: h

node = h.parent(
    h.child("first child content", id="id1"),
    h.child("second child content", id="id2")
)
# Node Element <parent> (2 children)

print(XML.write(node))
# <parent>
#   <child id="id1">first child content</child>
#   <child id="id2">second child content</child>
# </parent>
```

<br>

# Reading

Every reader shares the same entry points — the reader is the second argument:

```julia
read(filename, Node)     # or LazyNode, FlatNode, Cursor
parse(str, Node)         # or LazyNode, FlatNode, Cursor
```

`Cursor` can also be constructed directly from any `AbstractString`: `Cursor(str)`.

<br>

# Writing

```julia
XML.write(filename::String, node)  # write to file
XML.write(io::IO, node)            # write to stream
XML.write(node)                    # return String
```

`XML.write` respects `xml:space="preserve"` on elements, suppressing automatic indentation.

`XML.write` accepts `Node`, `LazyNode` (zero-copy of the original source; `normalize=true` re-parses and pretty-prints) and `FlatNode` (materializes through `Node` first). *Building* and *editing* documents is `Node`-only — the other readers are read-only.

<br>

# XPath

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

<br>

# `Cursor`

The forward, StAX-style pull reader: one mutable cursor walks the document in document order — no tree, one tokenizing scan, ~zero allocation. Advance with `next!`; read the current position with the usual accessors (`nodetype`, `tag`, `attributes`, `value`, `depth`):

```julia
cur = Cursor(xml_string)
while next!(cur) !== nothing
    nodetype(cur) === Element && tag(cur) == "book" && println(attributes(cur))
end
```

From a file or stream: `read(filename, Cursor)` / `read(io, Cursor)`, with the same byte-level BOM normalization as the tree readers (UTF-8 BOM strip, UTF-16 transcoding). The `Cursor(str)` constructor also accepts any `AbstractString` directly, including a `StringView` over `Mmap` for files too large for the heap (same recipe as under `LazyNode` below).

Two structured helpers carry the depth bookkeeping for you: `for_each_child(f, cur)` applies `f` to each *immediate* child of the current node (nestable — composing calls gives a full depth-first walk), and `skip_element!(cur)` jumps past the current element's entire subtree in one byte-level scan — the cheap way to classify nodes without tokenizing their contents. `@for_each_child` is the inlined-body macro form for hot extraction loops, and `Cursor(data, startpos)` starts a cursor at a known byte offset to walk just a subtree.

A `Cursor` is one object that *mutates* as it advances: every variable referring to it sees its current position, so read what you need while the loop is on the node. To keep a node's content beyond further `next!` calls, take an immutable snapshot of the position with `LazyNode(cur)`.

<br>

# `LazyNode`

For read-only access without building a full DOM tree, use `LazyNode`. It stores only a reference to the source string and re-tokenizes on demand, using significantly less memory:

```julia
doc = parse(xml_string, LazyNode)
doc = read("file.xml", LazyNode)
```

`LazyNode` supports the same read-only interface as `Node`: `nodetype`, `tag`, `attributes`, `value`, `children`, `is_simple`, `simple_value`, plus integer and string indexing.

`LazyNode` is for *partial* reads only: opening is a no-op wrapper (~0.5 µs whatever the file size) and you pay per node *touched* — a touch spans the node's subtree, and nothing is cached, so repeated visits pay the full price again. Unbeatable for leaf-ward hops and kilobyte-scale documents; for whole-tree walks (264 ms vs ~54/~100 ms build+walk on the 14 MB corpus below), repeated queries, or plucking one child out of a huge container, build `FlatNode` or `Node` instead — see [Performance by access pattern](#performance-by-access-pattern).

For streaming and high-throughput workloads, several extra accessors avoid materializing intermediate collections:

```julia
sourcetext(n)               # zero-copy SubString view of the node's raw source bytes
eachchildnode(n)            # lazy iterator over children — no Vector allocation
children!(buf, n)           # collect children into a reusable buffer
eachattribute(n)            # lazy iterator over attribute name=>value pairs
is_simple_value(n)          # combined is_simple + simple_value (one tokenizer pass)
get(n, key, default)        # single-attribute read without building Attributes
XML.write(n)                # zero-copy: returns node's original source text
XML.write(n; normalize=true) # re-parse + pretty-print, collapses source whitespace
```

### Memory-mapped files

Memory mapping is optional — `LazyNode`'s laziness is about *node materialization*, and it pays off on in-memory strings just as well. For files too large to read into heap memory, combine it with a `StringView` over `Mmap`:

```julia
using XML, Mmap, StringViews

doc = open("very_large.xml") do io
    sv = StringView(Mmap.mmap(io))
    parse(sv, LazyNode)
end
```

<br>

# `FlatNode` *(experimental)*

The whole document parsed once into a contiguous columnar store — the random-access read API of `Node` at almost none of its GC cost: fast build, O(1) random access and O(1) `parent`, and the garbage collector sees a handful of arrays instead of one object per node.

```julia
doc = parse(xml_string, FlatNode)     # or read("file.xml", FlatNode)
root = only(eachelement(doc))
for el in eachelement(root)
    tag(el), attributes(el), value(el)
end
```

Same read-only accessor surface as the other readers, including `sourcetext(node)` — the zero-copy `SubString` of a node's original source text, available on the two readers that retain the source (`FlatNode`, `LazyNode`) and not on `Node`. By design: read-only — creating or modifying documents is `Node`'s job; any live handle retains the whole store and source string; documents are limited to 2 GiB. `Node(flatnode)` materializes a handle (and its subtree) as a mutable `Node`; `XML.write` accepts a `FlatNode` directly. Positional identity — "same node of the same document" — is `issamenode(a, b)`.

> **Experimental** — new in v0.4.2: API details may still change in a 0.4.x release while ecosystem usage settles. Feedback welcome on the [issue tracker](https://github.com/JuliaData/XML.jl/issues).

<br>

# Under the hood

All four readers sit on `XML.XMLTokenizer`, a zero-allocation streaming tokenizer (a token is a kind plus a byte range into the source). It is usable directly for token-level tooling — see the `XML.XMLTokenizer` module docstrings.

<br>

# AbstractTrees Integration

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

# Performance by access pattern

One number cannot rank the readers — cost depends on what you do with the document. Same ~14 MB / 882 K-node XMark document as the cross-library table below, XML.jl v0.4.2 (source: [`benchmarks/flatnode_bench.jl`](benchmarks/flatnode_bench.jl); **lower is better**):

| | build | walk every node | extract all values | DOM size in memory |
|---|--:|--:|--:|--:|
| `Cursor` | — (streams) | 35.2 ms (its one scan) | — | — (no DOM) |
| `LazyNode` | ~0 (a wrapper) | 264 ms (re-tokenizes) | — | — (source only) |
| `FlatNode` | 50.5 ms | 3.0 ms | 10.2 ms | 54.9 MiB |
| `Node` | 93.7 ms | 5.8 ms | 6.3 ms | 80.0 MiB |
| EzXML (libxml2) | 37.9 ms | — | — | — |

Reading the table: `Cursor`'s walk *is* its parse — one tokenizing scan, nothing retained. `LazyNode` opens for free and pays per node visited — unbeatable for touching a *fraction* of a large document, and (as the walk column shows) the wrong tool for visiting all of it. `FlatNode` builds ~2× faster than `Node`, walks ~2× faster, holds ~30% less memory, and its `parent`/`depth` are O(1) where `Node` searches from the root; pure value extraction on an already-built tree is the one pattern where `Node`'s direct fields win. libxml2 still builds fastest — the remaining gap is materialization, not scanning (see [PERFORMANCE-v0.4.md](PERFORMANCE-v0.4.md)).

_Measured 2026-07-17, Apple M5 (single-threaded), Julia 1.12.6, EzXML 1.2.3._

<br>

# Benchmarks

Source: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl). Data: `books.xml` (~4 KB) and a generated XMark auction document (~14 MB). Median time, **lower is better.**

| Benchmark | XML.jl | EzXML | LightXML | XMLDict |
|---|--:|--:|--:|--:|
| Parse, small | 0.021 ms | 0.013 ms | 0.011 ms | 0.112 ms |
| Parse, medium | 109 ms | 46.9 ms | 47.2 ms | 357 ms |
| Write, small | 0.0056 ms | 0.0057 ms | 0.057 ms | — |
| Write, medium | 27.4 ms | 21.7 ms | 29.9 ms | — |
| Collect tags, small | 0.00037 ms | 0.0011 ms | 0.0018 ms | — |
| Collect tags, medium | 5.57 ms | 10.7 ms | 13.3 ms | — |

EzXML and LightXML wrap libxml2 (C): faster on raw parse, slower on in-Julia traversal.

For the per-access-pattern decomposition (streaming / partial reads / full DOM / stage breakdown) and the theory behind these numbers, see [**PERFORMANCE-v0.4.md**](PERFORMANCE-v0.4.md).

_Measured 2026-06-28/29, Apple M5 (single-threaded), Julia 1.12.6; EzXML 1.2.3 / LightXML 0.9.3 (libxml2 2.15.3), XMLDict 0.4.2. Source: [`benchmarks/benchmarks.jl`](benchmarks/benchmarks.jl)._
