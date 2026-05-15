[![CI](https://github.com/JuliaComputing/XML.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaComputing/XML.jl/actions/workflows/CI.yml)

<h1 align="center">XML.jl</h1>

<p align="center">Read and write XML in pure Julia.</p>

<br>

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

```julia
# From a file:
read(filename, Node)

# From a string:
parse(str, Node)
```

<br>

# Writing

```julia
XML.write(filename::String, node)  # write to file
XML.write(io::IO, node)            # write to stream
XML.write(node)                    # return String
```

`XML.write` respects `xml:space="preserve"` on elements, suppressing automatic indentation.

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

root = doc[end]

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
| `@attr` | Attribute value (returns strings) |

<br>

# Streaming Tokenizer

For large files or when you need fine-grained control, `XML.XMLTokenizer` provides a streaming tokenizer that yields tokens without building a DOM. Token kinds live in the `XML.XMLTokenizer.TokenKinds` baremodule (e.g. `TokenKinds.OPEN_TAG`, `TokenKinds.TEXT`).

```julia
using XML.XMLTokenizer: tokenize

for token in tokenize("<root><child attr=\"val\">text</child></root>")
    println(token.kind, " => ", repr(String(token.raw)))
end
# OPEN_TAG => "<root"
# TAG_CLOSE => ">"
# OPEN_TAG => "<child"
# ATTR_NAME => "attr"
# ATTR_VALUE => "\"val\""
# TAG_CLOSE => ">"
# TEXT => "text"
# CLOSE_TAG => "</child"
# TAG_CLOSE => ">"
# CLOSE_TAG => "</root"
# TAG_CLOSE => ">"
```

<br>

# `LazyNode`

For read-only access without building a full DOM tree, use `LazyNode`. It stores only a reference to the source string and re-tokenizes on demand, using significantly less memory:

```julia
doc = parse(xml_string, LazyNode)
doc = read("file.xml", LazyNode)
```

`LazyNode` supports the same read-only interface as `Node`: `nodetype`, `tag`, `attributes`, `value`, `children`, `is_simple`, `simple_value`, plus integer and string indexing.

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

For very large files, combine `LazyNode` with memory mapping to avoid reading the entire file into heap memory:

```julia
using XML, Mmap, StringViews

doc = open("very_large.xml") do io
    sv = StringView(Mmap.mmap(io))
    parse(sv, LazyNode)
end
```

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

# Benchmarks

Benchmark source: [benchmarks.jl](benchmarks/benchmarks.jl).  Test data: `books.xml` (small, ~4 KB) and a generated XMark auction XML (medium, ~14 MB).



```
                         Parse (small) — median time (ms)

        XML.jl  ■■■■■■■ 0.0374
   XML.jl (SS)  ■■■■■■■ 0.0339
         EzXML  ■■■■ 0.0218
      LightXML  ■■■■ 0.0218
       XMLDict  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 0.200


                         Parse (medium) — median time (ms)

        XML.jl  ■■■■■■■■■■■■■■ 185.0
   XML.jl (SS)  ■■■■■■■■■■■■■ 168.0
         EzXML  ■■■■■■ 81.5
      LightXML  ■■■■■■■■ 107.0
       XMLDict  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 520.0


                      Write (small) — median time (ms)

     XML.jl  ■■■■ 0.00929
      EzXML  ■■■■ 0.0103
   LightXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 0.101


                      Write (medium) — median time (ms)

     XML.jl  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 48.0
      EzXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 52.6
   LightXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 56.1


                        Read file — median time (ms)

     XML.jl  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 193.0
      EzXML  ■■■■■■■■■■■■■■■■■■■■■■■■■ 121.0
   LightXML  ■■■■■■■■■■■■■■■■■■■■ 95.6


                   Collect tags (small) — median time (ms)

     XML.jl  ■■■■■■ 0.000586
      EzXML  ■■■■■■■■■■■■■■■■■■■■■■ 0.00205
   LightXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 0.00368


                  Collect tags (medium) — median time (ms)

     XML.jl  ■■■■■■■■■■■■■■■■■■ 13.1
      EzXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 29.4
   LightXML  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 23.2
```

```julia
versioninfo()
# Julia Version 1.12.6
# Commit 15346901f00 (2026-04-09 19:20 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin24.0.0)
#   CPU: 10 × Apple M1 Pro
#   WORD_SIZE: 64
#   LLVM: libLLVM-18.1.7 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 8 default, 1 interactive, 8 GC (on 8 virtual cores)
# Environment:
#   JULIA_NUM_THREADS = auto
```
