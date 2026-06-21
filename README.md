[![CI](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaData/XML.jl/actions/workflows/CI.yml) [![codecov](https://codecov.io/gh/JuliaData/XML.jl/graph/badge.svg)](https://codecov.io/gh/JuliaData/XML.jl)

<h1 align="center">XML.jl</h1>

<p align="center">Read and write XML in pure Julia.</p>

<br><br>

# Introduction

This package offers fast data structures for reading and writing XML files with a consistent interface:

<br>

### `Node`/`LazyNode` Interface:

```
nodetype(node)      →   XML.NodeType (an enum type)
tag(node)           →   String or Nothing
attributes(node)    →   OrderedDict{String, String} or Nothing
value(node)         →   String or Nothing
children(node)      →   Vector{typeof(node)}
is_simple(node)     →   Bool (whether node is simple .e.g. <tag>item</tag>)
simple_value(node)   →   e.g. "item" from <tag>item</tag>)
```

<br>

### Extended Interface for `LazyNode`

```
depth(node)         →   Int
next(node)          →   typeof(node)
prev(node)          →   typeof(node)
parent(node)        →   typeof(node)
```

<br><br>

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

<br><br>

# Data Structures that Represent XML Nodes

## Preliminary: `NodeType`

- Each item in an XML DOM is classified by its `NodeType`.
- Every `XML.jl` struct defines a `nodetype(x)` method that returns its `NodeType`.

| NodeType | XML Representation | `Node` Constructor |
|----------|--------------------|------------------|
| `Document` | An entire document | `Document(children...)`
| `DTD` | `<!DOCTYPE ...>` | `DTD(...) `
| `Declaration` | `<?xml attributes... ?>` | `Declaration(; attrs...)`
| `ProcessingInstruction` | `<?tag attributes... ?>` | `ProcessingInstruction(tag; attrs...)`
| `Comment` | `<!-- text -->` | `Comment(text)`
| `CData` | `<![CDATA[text]]>` | `CData(text)`
| `Element` | `<tag attributes... > children... </NAME>` | `Element(tag, children...; attrs...)`
| `Text` | the `text` part of `<tag>text</tag>` | `Text(text)`

<br>

## `Node`: Probably What You're Looking For

- `read`-ing a `Node` loads the entire XML DOM in memory.
- See the table above for convenience constructors.
- `Node`s have some additional methods that aid in construction/mutation:

```julia
# Add a child:
push!(parent::Node, child::Node)

# Replace a child:
parent[2] = child

# Add/change an attribute:
node["key"] = value

node["key"]
```

- `Node` is an immutable type.  However, you can easily create a copy with one or more field values changed by using the `Node(::Node, children...; attrs...)` constructor where `children` are appended to the source node's children and `attrs` are appended to the node's attributes.

```julia
node = XML.Element("tag", "child")
# Node Element <tag> (1 child)

simple_value(node)
# "child"

node2 = Node(node, "added"; id="my-id")
# Node Element <tag id="my-id"> (2 children)

node2.children
# 2-element Vector{Node}:
#  Node Text "child"
#  Node Text "added"
```

### Writing `Element` `Node`s with `XML.h`

Similar to [Cobweb.jl](https://github.com/JuliaComputing/Cobweb.jl#-creating-nodes-with-cobwebh), `XML.h` enables you to write elements with a simpler syntax:

```julia
using XML: h

julia> node = h.parent(
         h.child("first child content", id="id1"),
         h.child("second child content", id="id2")
       )
# Node Element <parent> (2 children)

julia> print(XML.write(node))
# <parent>
#   <child id="id1">first child content</child>
#   <child id="id2">second child content</child>
# </parent>
```

<br>

## `XML.LazyNode`: For Fast Iteration through an XML File

A lazy data structure that just keeps track of the position in the raw data (`Vector{UInt8}`) to read from.

- You can iterate over a `LazyNode` to "read" through an XML file:

```julia
doc = read(filename, LazyNode)

foreach(println, doc)
# LazyNode Declaration <?xml version="1.0"?>
# LazyNode Element <catalog>
# LazyNode Element <book id="bk101">
# LazyNode Element <author>
# LazyNode Text "Gambardella, Matthew"
# LazyNode Element <title>
# ⋮
```

<br><br>

# Reading

```julia
# Reading from file:
read(filename, Node)
read(filename, LazyNode)

# Parsing from string:
parse(Node, str)
parse(LazyNode, str)

```

<br><br>

# Writing

```julia
XML.write(filename::String, node)  # write to file

XML.write(io::IO, node)  # write to stream

XML.write(node)  # String
```


<br><br>

# Performance

- XML.jl performs comparatively to [EzXML.jl](https://github.com/JuliaIO/EzXML.jl), which wraps the C library [libxml2](https://gitlab.gnome.org/GNOME/libxml2/-/wikis/home).
- See the `benchmarks/suite.jl` for the code to produce these results.
- The following output was generated in a Julia session with the following `versioninfo`:

```
julia> versioninfo()
Julia Version 1.9.4
Commit 8e5136fa297 (2023-11-14 08:46 UTC)
Build Info:
  Official https://julialang.org/ release
Platform Info:
  OS: macOS (arm64-apple-darwin22.4.0)
  CPU: 10 × Apple M1 Pro
  WORD_SIZE: 64
  LIBM: libopenlibm
  LLVM: libLLVM-14.0.6 (ORCJIT, apple-m1)
  Threads: 8 on 8 virtual cores
```


### Reading an XML File

```
       XML.LazyNode   0.009583
           XML.Node  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 1071.32
      EzXML.readxml  ■■■■■■■■■ 284.346
   XMLDict.xml_dict  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 1231.47
```

### Writing an XML File

```
         Write: XML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 289.638
       Write: EzXML  ■■■■■■■■■■■■■ 93.4631
```

### Lazily Iterating over Each Node
```
           LazyNode  ■■■■■■■■■ 51.752
 EzXML.StreamReader  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 226.271
```

### Collecting All Names/Tags in an XML File
```
       XML.LazyNode  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 210.482
 EzXML.StreamReader  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 276.238
      EzXML.readxml  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 263.269
```

<br>
<br>

# Possible Gotchas

- XML.jl doesn't automatically escape special characters (`<`, `>`, `&`, `"`, and `'` ) for you.  However, we provide utility functions for doing the conversions back and forth:
  - `XML.escape(::String)` and `XML.unescape(::String)`
  - `XML.escape!(::Node)` and `XML.unescape!(::Node)`.
