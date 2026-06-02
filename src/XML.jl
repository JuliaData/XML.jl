module XML

export
    Node, LazyNode, NodeType, Attributes,
    CData, Comment, Declaration, Document, DTD, Element, ProcessingInstruction, Text,
    nodetype, tag, attributes, value, children, children!, eachchildnode, eachattribute,
    is_simple, simple_value, is_simple_value, sourcetext,
    depth, siblings,
    Cursor, next!, for_each_child, eof,
    xpath,
    h

include("XMLTokenizer.jl")
using .XMLTokenizer:
    XMLTokenizer, tokenize, tag_name, attr_value, pi_target, raw,
    TokenKinds, Token, Tokenizer, TokenizerState

#-----------------------------------------------------------------------------# escape/unescape
const ESCAPE_CHARS = ('&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '\'' => "&apos;", '"' => "&quot;")

"""
    escape(x::AbstractString) -> String

Escape the five XML predefined entities: `&` `<` `>` `'` `"`.

!!! note "Changed in v0.4"
    `escape` is no longer idempotent.  In previous versions, already-escaped sequences like
    `&amp;` were left untouched.  Now every `&` is escaped, so `escape("&amp;")` produces
    `"&amp;amp;"`.  Call `escape` only on raw, unescaped text.
"""
escape(x::AbstractString) = replace(x, ESCAPE_CHARS...)

# Replace a numeric character reference with its Unicode character.
# Numeric character references encode characters by code point: decimal (&#233; → é) or hex (&#xE9; → é).
function _unescape_charref(ref::AbstractString)
    is_hex = length(ref) > 3 && ref[3] in ('x', 'X')
    digits = SubString(ref, is_hex ? 4 : 3, length(ref) - 1)
    cp = tryparse(UInt32, digits; base = is_hex ? 16 : 10)
    !isnothing(cp) && isvalid(Char, cp) ? string(Char(cp)) : ref
end

"""
    unescape(x::AbstractString) -> String
    unescape(x::SubString{String}) -> Union{SubString{String}, String}

Unescape XML entities in `x`: the five predefined entities (`&amp;` `&lt;` `&gt;` `&apos;`
`&quot;`) and numeric character references (`&#123;`, `&#xAB;`). Each reference is processed
exactly once (no double-unescaping).

When `x` is a `SubString{String}` containing no `&`, the input is returned unchanged with
no allocation — the common case for typical XML attribute and text content.
"""
function unescape(x::AbstractString)
    s = string(x)
    occursin('&', s) || return s
    occursin("&#", s) && (s = replace(s, r"&#[xX]?[0-9a-fA-F]+;" => _unescape_charref))
    replace(s, "&lt;" => "<", "&gt;" => ">", "&apos;" => "'", "&quot;" => "\"", "&amp;" => "&")
end

function unescape(x::SubString{String})
    occursin('&', x) || return x
    s = String(x)
    occursin("&#", s) && (s = replace(s, r"&#[xX]?[0-9a-fA-F]+;" => _unescape_charref))
    replace(s, "&lt;" => "<", "&gt;" => ">", "&apos;" => "'", "&quot;" => "\"", "&amp;" => "&")
end

#-----------------------------------------------------------------------------# NodeType
"""
    NodeType:
    - Document                  # prolog & root Element
    - DTD                       # <!DOCTYPE ...>
    - Declaration               # <?xml attributes... ?>
    - ProcessingInstruction    # <?NAME content... ?>
    - Comment                   # <!-- ... -->
    - CData                     # <![CDATA[...]]>
    - Element                   # <NAME attributes... > children... </NAME>
    - Text                      # text

NodeTypes can be used to construct XML.Nodes:

    Document(children...)
    DTD(value)
    Declaration(; attributes)
    ProcessingInstruction(tag, content)
    Comment(text)
    CData(text)
    Element(tag, children...; attributes)
    Text(text)
"""
@enum NodeType::UInt8 CData Comment Declaration Document DTD Element ProcessingInstruction Text

#-----------------------------------------------------------------------------# Attributes
"""
    Attributes{S} <: AbstractDict{S, S}

An ordered dictionary of XML attributes backed by a `Vector{Pair{S, S}}`.
Returned by [`attributes`](@ref).  Preserves insertion order and supports the
full `AbstractDict` interface (`get`, `haskey`, `keys`, `values`, iteration, etc.).
"""
struct Attributes{S} <: AbstractDict{S, S}
    entries::Vector{Pair{S, S}}
end

Base.length(a::Attributes) = length(a.entries)
Base.iterate(a::Attributes, state...) = iterate(a.entries, state...)

function Base.getindex(a::Attributes, key::AbstractString)
    for (k, v) in a.entries
        k == key && return v
    end
    throw(KeyError(key))
end

function Base.get(a::Attributes, key::AbstractString, default)
    for (k, v) in a.entries
        k == key && return v
    end
    default
end

function Base.haskey(a::Attributes, key::AbstractString)
    any(p -> first(p) == key, a.entries)
end

Base.keys(a::Attributes) = first.(a.entries)
Base.values(a::Attributes) = last.(a.entries)

#-----------------------------------------------------------------------------# Node
"""
    Node{S}

In-memory DOM node parameterized on the string storage type `S` (typically `String`, or
`SubString{String}` for zero-copy parsing). Every kind of XML node — `Element`, `Text`,
`Comment`, `CData`, `ProcessingInstruction`, `Declaration`, `DTD`, `Document` — is
represented by a single `Node{S}` whose [`NodeType`](@ref) determines which fields are
populated.

    parse(xml, Node)             # parse a string into a Node{String}
    parse(xml, Node{SubString{String}})  # zero-copy variant
    read(filename, Node)         # read & parse a file

Use the accessor functions ([`nodetype`](@ref), [`tag`](@ref), [`attributes`](@ref),
[`value`](@ref), [`children`](@ref)) rather than the raw fields when navigating a tree.
Integer indexing returns children (`node[1]`); string indexing returns attribute values
(`node["class"]`).
"""
struct Node{S}
    nodetype::NodeType
    tag::Union{Nothing, S}
    attributes::Union{Nothing, Vector{Pair{S, S}}}
    value::Union{Nothing, S}
    children::Union{Nothing, Vector{Node{S}}}

    function Node{S}(nodetype::NodeType, tag, attributes, value, children) where {S}
        if nodetype in (Text, Comment, CData, DTD)
            isnothing(tag) && isnothing(attributes) && !isnothing(value) && isnothing(children) ||
                error("$nodetype nodes only accept a value.")
        elseif nodetype === Element
            !isnothing(tag) && isnothing(value) ||
                error("Element nodes require a tag and no value.")
        elseif nodetype === Declaration
            isnothing(tag) && isnothing(value) && isnothing(children) ||
                error("Declaration nodes only accept attributes.")
        elseif nodetype === ProcessingInstruction
            !isnothing(tag) && isnothing(attributes) && isnothing(children) ||
                error("ProcessingInstruction nodes require a tag and only accept a value.")
        elseif nodetype === Document
            isnothing(tag) && isnothing(attributes) && isnothing(value) ||
                error("Document nodes only accept children.")
        end
        new{S}(nodetype, tag, attributes, value, children)
    end
end

#-----------------------------------------------------------------------------# interface
"""
    nodetype(node) -> NodeType

Return the [`NodeType`](@ref) of `node` (`Element`, `Text`, `Comment`, `CData`,
`ProcessingInstruction`, `Declaration`, `DTD`, or `Document`).
"""
nodetype(o::Node) = o.nodetype

"""
    tag(node) -> Union{String, SubString{String}, Nothing}

Return the tag name of `node`. Defined for `Element` (element name) and
`ProcessingInstruction` (target name); returns `nothing` for other node types.
"""
tag(o::Node) = o.tag

"""
    attributes(node::Node) -> Union{Nothing, Attributes{String}}

Return the attributes of an `Element` or `Declaration` node as an [`Attributes`](@ref) dict,
or `nothing` if the node has no attributes.

!!! note "Changed in v0.4"
    In previous versions, `attributes` returned an `OrderedDict` from OrderedCollections.jl.
    It now returns an [`Attributes`](@ref), an ordered `AbstractDict` backed by a
    `Vector{Pair}`.
"""
attributes(o::Node) = isnothing(o.attributes) ? nothing : Attributes(o.attributes)

"""
    value(node) -> Union{String, SubString{String}, Nothing}

Return the textual content of `node`. Defined for `Text`, `Comment`, `CData`, `DTD`, and
`ProcessingInstruction`; returns `nothing` for `Element`, `Declaration`, and `Document`
(use [`children`](@ref) for those).
"""
value(o::Node) = o.value

"""
    children(node) -> Vector{Node} or ()

Return the child nodes of `node` in document order. Returns an empty tuple `()` for nodes
that cannot have children (e.g. `Text`, `Comment`, `CData`).
"""
children(o::Node) = something(o.children, ())

"""
    is_simple(node) -> Bool

Return `true` if `node` is an `Element` with no attributes and exactly one `Text` or
`CData` child — i.e. the `<tag>content</tag>` pattern with no nested markup. See also
[`simple_value`](@ref).
"""
is_simple(o::Node) = o.nodetype === Element &&
    (isnothing(o.attributes) || isempty(o.attributes)) &&
    !isnothing(o.children) && length(o.children) == 1 &&
    o.children[1].nodetype in (Text, CData)

"""
    simple_value(node) -> String

Return the textual content of a simple element (see [`is_simple`](@ref)). Errors if
`node` is not simple.
"""
simple_value(o::Node) = is_simple(o) ? o.children[1].value :
    error("`simple_value` is only defined for simple nodes.")

"""
    is_simple_value(node) -> Union{Nothing, String, SubString{String}}

Combined predicate-and-accessor: return the simple text/CData value of `node` if it is a
simple element (see [`is_simple`](@ref)), or `nothing` otherwise. Avoids the redundant
tokenization that `is_simple(n) ? simple_value(n) : ...` does on `LazyNode`.
"""
is_simple_value(o::Node) = is_simple(o) ? o.children[1].value : nothing

#-----------------------------------------------------------------------------# tree navigation

"""
    parent(child::Node, root::Node) -> Node

Return the parent of `child` within the tree rooted at `root`.

Since `Node` does not store parent pointers, this performs a tree search from `root`.
Throws an error if `child` is not found or if `child === root`.
"""
function Base.parent(child::Node, root::Node)
    child === root && error("Root node has no parent.")
    result = _find_parent(child, root)
    isnothing(result) && error("Node not found in tree.")
    result
end

# Depth-first search for `child` within `current`; returns the containing node or nothing.
function _find_parent(child::Node, current::Node)
    for c in children(current)
        c === child && return current
        result = _find_parent(child, c)
        isnothing(result) || return result
    end
    nothing
end

"""
    depth(child::Node, root::Node) -> Int

Return the depth of `child` within the tree rooted at `root` (root has depth 0).

Since `Node` does not store parent pointers, this performs a tree search from `root`.
Throws an error if `child` is not found in the tree.
"""
function depth(child::Node, root::Node)
    child === root && return 0
    result = _find_depth(child, root, 0)
    isnothing(result) && error("Node not found in tree.")
    result
end

# Depth-first search returning the depth of `child` relative to `current` (where children
# of `current` are at depth `d + 1`), or nothing if not found.
function _find_depth(child::Node, current::Node, d::Int)
    for c in children(current)
        c === child && return d + 1
        result = _find_depth(child, c, d + 1)
        isnothing(result) || return result
    end
    nothing
end

"""
    siblings(child::Node, root::Node) -> Vector{Node}

Return the siblings of `child` (other children of the same parent) within the tree rooted
at `root`.  The returned vector does not include `child` itself.

Throws an error if `child` is the root or is not found in the tree.
"""
function siblings(child::Node, root::Node)
    p = parent(child, root)
    [c for c in children(p) if c !== child]
end

include("xpath.jl")
include("lazynode.jl")
include("cursor.jl")


#-----------------------------------------------------------------------------# _to_node
# Coerce a positional argument to a Node{String}: identity for nodes, wrap non-nodes as
# Text. The middle method rejects non-String parameterizations to keep mixed-storage trees
# from being silently constructed.
_to_node(n::Node{String}) = n
_to_node(n::Node) = throw(ArgumentError("Expected Node{String}, got $(typeof(n))"))
_to_node(x) = Node{String}(Text, nothing, nothing, string(x), nothing)

#-----------------------------------------------------------------------------# NodeType constructors
# Make each NodeType variant callable as a constructor: `Element("div", ...)`,
# `Text("hi")`, etc. Dispatches on `T` to validate args/kwargs and build the right Node.
function (T::NodeType)(args...; attrs...)
    S = String
    if T in (Text, Comment, CData, DTD)
        length(args) == 1 || error("$T nodes require exactly one value argument.")
        !isempty(attrs) && error("$T nodes do not accept attributes.")
        Node{S}(T, nothing, nothing, string(only(args)), nothing)
    elseif T === Element
        isempty(args) && error("Element nodes require at least a tag.")
        t = string(first(args))
        a = Pair{S,S}[String(k) => String(v) for (k, v) in pairs(attrs)]
        c = Node{S}[_to_node(x) for x in args[2:end]]
        Node{S}(T, t, a, nothing, c)
    elseif T === Declaration
        !isempty(args) && error("Declaration nodes only accept keyword attributes.")
        a = isempty(attrs) ? nothing : [String(k) => String(v) for (k, v) in pairs(attrs)]
        Node{S}(T, nothing, a, nothing, nothing)
    elseif T === ProcessingInstruction
        length(args) >= 1 || error("ProcessingInstruction nodes require a target.")
        length(args) <= 2 || error("ProcessingInstruction nodes accept a target and optional content.")
        !isempty(attrs) && error("ProcessingInstruction nodes do not accept attributes.")
        t = string(args[1])
        v = length(args) == 2 ? string(args[2]) : nothing
        Node{S}(T, t, nothing, v, nothing)
    elseif T === Document
        !isempty(attrs) && error("Document nodes do not accept attributes.")
        c = Node{S}[_to_node(x) for x in args]
        Node{S}(T, nothing, nothing, nothing, c)
    end
end

#-----------------------------------------------------------------------------# equality
# Treat `nothing` and an empty collection as equivalent so that an absent attribute /
# children field compares equal to an explicitly empty one.
_eq(::Nothing, ::Nothing) = true
_eq(::Nothing, b) = isempty(b)
_eq(a, ::Nothing) = isempty(a)
_eq(a, b) = a == b

# Attribute equality is order-insensitive per XML spec.
function _attrs_eq(a, b)
    a_empty = isnothing(a) || isempty(a)
    b_empty = isnothing(b) || isempty(b)
    a_empty && b_empty && return true
    (a_empty != b_empty) && return false
    length(a) != length(b) && return false
    for p in a
        p in b || return false
    end
    true
end

function Base.:(==)(a::Node, b::Node)
    a.nodetype == b.nodetype &&
    a.tag == b.tag &&
    _attrs_eq(a.attributes, b.attributes) &&
    a.value == b.value &&
    _eq(a.children, b.children)
end

#-----------------------------------------------------------------------------# indexing
Base.getindex(o::Node, i::Integer) = children(o)[i]
Base.getindex(o::Node, ::Colon) = children(o)
Base.lastindex(o::Node) = lastindex(children(o))
Base.only(o::Node) = only(children(o))
Base.length(o::Node) = length(children(o))

function Base.get(o::Node, key::AbstractString, default)
    isnothing(o.attributes) && return default
    for (k, v) in o.attributes
        k == key && return v
    end
    default
end

const _MISSING_ATTR = gensym(:missing_attr)

function Base.getindex(o::Node, key::AbstractString)
    val = get(o, key, _MISSING_ATTR)
    val === _MISSING_ATTR && throw(KeyError(key))
    val
end

function Base.haskey(o::Node, key::AbstractString)
    get(o, key, _MISSING_ATTR) !== _MISSING_ATTR
end

Base.keys(o::Node) = isnothing(o.attributes) ? () : first.(o.attributes)

#-----------------------------------------------------------------------------# mutation
function Base.setindex!(o::Node, val, i::Integer)
    isnothing(o.children) && error("Node has no children.")
    o.children[i] = _to_node(val)
end

function Base.setindex!(o::Node, val, key::AbstractString)
    isnothing(o.attributes) && error("Node has no attributes.")
    v = string(val)
    for i in eachindex(o.attributes)
        if first(o.attributes[i]) == key
            o.attributes[i] = key => v
            return v
        end
    end
    push!(o.attributes, key => v)
    v
end

function Base.push!(a::Node, b)
    isnothing(a.children) && error("Node does not accept children.")
    push!(a.children, _to_node(b))
    a
end

function Base.pushfirst!(a::Node, b)
    isnothing(a.children) && error("Node does not accept children.")
    pushfirst!(a.children, _to_node(b))
    a
end

#-----------------------------------------------------------------------------# show (REPL)
function Base.show(io::IO, o::Node)
    nt = o.nodetype
    print(io, nt)
    if nt === Text
        print(io, ' ', repr(o.value))
    elseif nt === Element
        print(io, " <", o.tag)
        if !isnothing(o.attributes)
            for (k, v) in o.attributes
                print(io, ' ', k, '=', '"', v, '"')
            end
        end
        print(io, '>')
        n = length(children(o))
        n > 0 && print(io, n == 1 ? " (1 child)" : " ($n children)")
    elseif nt === DTD
        print(io, " <!DOCTYPE ", o.value, '>')
    elseif nt === Declaration
        print(io, " <?xml")
        if !isnothing(o.attributes)
            for (k, v) in o.attributes
                print(io, ' ', k, '=', '"', v, '"')
            end
        end
        print(io, "?>")
    elseif nt === ProcessingInstruction
        print(io, " <?", o.tag)
        !isnothing(o.value) && print(io, ' ', o.value)
        print(io, "?>")
    elseif nt === Comment
        print(io, " <!--", o.value, "-->")
    elseif nt === CData
        print(io, " <![CDATA[", o.value, "]]>")
    elseif nt === Document
        n = length(children(o))
        n > 0 && print(io, n == 1 ? " (1 child)" : " ($n children)")
    end
end

#-----------------------------------------------------------------------------# show (text/xml)

# Write XML-escaped content directly to IO (single pass, no intermediate string)
function _write_escaped(io::IO, s::String)
    start = 1
    i = 1
    n = ncodeunits(s)
    @inbounds while i <= n
        b = codeunit(s, i)
        esc = if b == UInt8('&'); "&amp;"
        elseif b == UInt8('<'); "&lt;"
        elseif b == UInt8('>'); "&gt;"
        elseif b == UInt8('"'); "&quot;"
        elseif b == UInt8('\''); "&apos;"
        else
            i += 1
            continue
        end
        i > start && GC.@preserve s Base.unsafe_write(io, pointer(s, start), (i - start) % UInt)
        print(io, esc)
        i += 1
        start = i
    end
    start <= n && GC.@preserve s Base.unsafe_write(io, pointer(s, start), (n - start + 1) % UInt)
    nothing
end

# Cached indentation strings to avoid repeated allocation
const _MAX_CACHED_INDENT = 64
const _INDENT_STRINGS = [" " ^ n for n in 0:_MAX_CACHED_INDENT]
@inline function _indent_str(n::Int)
    0 <= n <= _MAX_CACHED_INDENT && return @inbounds _INDENT_STRINGS[n + 1]
    " " ^ n
end

# Serialize `key="escaped-value"` pairs for an attributes vector (no leading space outside).
# Uses byte-level `Base.write` instead of `print` to avoid the varargs-print dispatch
# overhead that shows up under profile when an element has many attributes.
function _print_attrs(io::IO, attributes)
    isnothing(attributes) && return
    for (k, v) in attributes
        Base.write(io, UInt8(' '))
        Base.write(io, k)
        Base.write(io, UInt8('='))
        Base.write(io, UInt8('"'))
        _write_escaped(io, v)
        Base.write(io, UInt8('"'))
    end
end

# Whitespace-only Text — emitted by the parser to round-trip source whitespace; pretty
# printing regenerates indentation from the tree shape and drops these.
@inline function _is_ignorable_text(node::Node)
    node.nodetype === Text && !isnothing(node.value) && all(isspace, node.value)
end

# Mixed content = at least one Text/CData child carrying actual (non-whitespace) data.
# In that case the original whitespace is significant and we must not reformat.
function _has_significant_text(children)
    for c in children
        nt = c.nodetype
        if nt === Text
            (!isnothing(c.value) && !all(isspace, c.value)) && return true
        elseif nt === CData
            return true
        end
    end
    false
end

# Main XML serializer. `depth` controls indentation; `preserve` propagates `xml:space=
# "preserve"` semantics down the subtree so we don't reformat whitespace-sensitive content.
function _write_xml(io::IO, node::Node, depth::Int=0, indent::Int=2, preserve::Bool=false)
    pad = preserve ? "" : _indent_str(indent * depth)
    nt = node.nodetype
    if nt === Text
        _write_escaped(io, node.value)
    elseif nt === Element
        # Check xml:space on this element
        child_preserve = preserve
        if !isnothing(node.attributes)
            for (k, v) in node.attributes
                k == "xml:space" && (child_preserve = v == "preserve")
            end
        end
        Base.write(io, pad)
        Base.write(io, UInt8('<'))
        Base.write(io, node.tag)
        _print_attrs(io, node.attributes)
        ch = node.children
        if isnothing(ch) || isempty(ch)
            Base.write(io, UInt8('/'))
            Base.write(io, UInt8('>'))
        elseif length(ch) == 1 && only(ch).nodetype === Text
            Base.write(io, UInt8('>'))
            _write_xml(io, only(ch), 0, 0, child_preserve)
            Base.write(io, UInt8('<'))
            Base.write(io, UInt8('/'))
            Base.write(io, node.tag)
            Base.write(io, UInt8('>'))
        else
            # If real Text or any CData lives among the children, treat as mixed
            # content and preserve the original layout. Otherwise pretty-print
            # and skip whitespace-only Text children — those were emitted by the
            # parser purely to round-trip source whitespace, and the writer
            # regenerates indentation from the tree shape.
            effective_preserve = child_preserve || _has_significant_text(ch)
            if effective_preserve
                Base.write(io, UInt8('>'))
            else
                Base.write(io, UInt8('>'))
                Base.write(io, UInt8('\n'))
            end
            for child in ch
                if !effective_preserve && _is_ignorable_text(child)
                    continue
                end
                _write_xml(io, child, depth + 1, indent, effective_preserve)
                effective_preserve || Base.write(io, UInt8('\n'))
            end
            effective_preserve || Base.write(io, pad)
            Base.write(io, UInt8('<'))
            Base.write(io, UInt8('/'))
            Base.write(io, node.tag)
            Base.write(io, UInt8('>'))
        end
    elseif nt === Declaration
        Base.write(io, pad)
        Base.write(io, "<?xml")
        _print_attrs(io, node.attributes)
        Base.write(io, "?>")
    elseif nt === ProcessingInstruction
        Base.write(io, pad)
        Base.write(io, "<?")
        Base.write(io, node.tag)
        if !isnothing(node.value)
            Base.write(io, UInt8(' '))
            Base.write(io, node.value)
        end
        Base.write(io, "?>")
    elseif nt === Comment
        Base.write(io, pad)
        Base.write(io, "<!--")
        Base.write(io, node.value)
        Base.write(io, "-->")
    elseif nt === CData
        Base.write(io, pad)
        Base.write(io, "<![CDATA[")
        Base.write(io, node.value)
        Base.write(io, "]]>")
    elseif nt === DTD
        Base.write(io, pad)
        Base.write(io, "<!DOCTYPE ")
        Base.write(io, node.value)
        Base.write(io, UInt8('>'))
    elseif nt === Document
        ch = node.children
        if !isnothing(ch)
            # Drop whitespace-only Text between top-level nodes when pretty
            # printing (XML grammar disallows text at document level, so any
            # such Text comes from inter-node whitespace in the source).
            visible = preserve ? ch : filter(!_is_ignorable_text, ch)
            n_visible = length(visible)
            for (i, child) in enumerate(visible)
                _write_xml(io, child, 0, indent, preserve)
                i < n_visible && Base.write(io, UInt8('\n'))
            end
        end
    end
end

Base.show(io::IO, ::MIME"text/xml", node::Node) = _write_xml(io, node)

#-----------------------------------------------------------------------------# write / read
write(node::Node; indentsize::Int=2) = (io = IOBuffer(); _write_xml(io, node, 0, indentsize); String(take!(io)))
write(filename::AbstractString, node::Node; kw...) = open(io -> write(io, node; kw...), filename, "w")
write(io::IO, node::Node; indentsize::Int=2) = _write_xml(io, node, 0, indentsize)

Base.read(filename::AbstractString, ::Type{Node}) = parse(read(filename, String), Node)
Base.read(io::IO, ::Type{Node}) = parse(read(io, String), Node)

#-----------------------------------------------------------------------------# parse
Base.parse(::Type{Node}, xml::AbstractString) = parse(xml, Node)

function Base.parse(xml::AbstractString, ::Type{Node})
    _parse(String(xml), String, unescape)
end

function Base.parse(xml::AbstractString, ::Type{Node{SubString{String}}})
    _parse(String(xml), SubString{String}, identity)
end

# Convert a parser substring to the requested storage type — copy to a fresh String, or
# keep the zero-copy SubString view.
_to(::Type{String}, s::AbstractString) = String(s)
_to(::Type{SubString{String}}, s::SubString{String}) = s

# Collapse an empty Vector to `nothing` so Node fields store "absent" canonically.
_nothingify(v::Vector) = isempty(v) ? nothing : v

# Decode the raw bytes of a TEXT/ATTR_VALUE token into the parser's storage type. When the
# tokenizer guarantees no `&` was seen (`has_entities=false`), we skip the entity-decode
# pass entirely. The `convert_text=identity` specialization (SubString parse) skips the
# runtime branch as well — both arms would return the same value.
@inline _text_value(::Type{S}, raw, _, ::typeof(identity)) where {S} = _to(S, raw)
@inline _text_value(::Type{S}, raw, has_entities, convert_text::F) where {S, F} =
    has_entities ? convert_text(raw) : _to(S, raw)

# Token-stream → Node{S} builder. `convert_text` is `unescape` for parsed content (with
# entity decoding) and `identity` for zero-copy SubString parsing where the caller opts
# to keep raw escapes.
function _parse(xml::String, ::Type{S}, convert_text::F) where {S, F}
    tags = S[]
    attrs_stack = Vector{Pair{S,S}}[]
    children_stack = Vector{Vector{Node{S}}}()
    push!(children_stack, Node{S}[])

    pending_attr_name = SubString(xml, 1, 0)
    decl_attrs = nothing
    pending_pi_tag = SubString(xml, 1, 0)
    pending_pi_value = nothing
    in_close_tag = false

    for token in tokenize(xml)
        k = token.kind

        if k === TokenKinds.TEXT
            v = _text_value(S, raw(token, xml), token.has_entities, convert_text)
            push!(last(children_stack), Node{S}(Text, nothing, nothing, v, nothing))

        elseif k === TokenKinds.OPEN_TAG
            push!(tags, _to(S, tag_name(token, xml)))
            push!(attrs_stack, Pair{S,S}[])
            push!(children_stack, Node{S}[])

        elseif k === TokenKinds.SELF_CLOSE
            t = pop!(tags)
            a = pop!(attrs_stack)
            pop!(children_stack)
            push!(last(children_stack), Node{S}(Element, t, _nothingify(a), nothing, nothing))

        elseif k === TokenKinds.TAG_CLOSE
            in_close_tag && (in_close_tag = false)

        elseif k === TokenKinds.CLOSE_TAG
            close_name = tag_name(token, xml)
            isempty(tags) && error("Closing tag </$close_name> with no matching open tag.")
            t = pop!(tags)
            t == close_name || error("Mismatched tags: expected </$t>, got </$close_name>.")
            a = pop!(attrs_stack)
            c = pop!(children_stack)
            push!(last(children_stack), Node{S}(Element, t, _nothingify(a), nothing, isempty(c) ? nothing : c))
            in_close_tag = true

        elseif k === TokenKinds.ATTR_NAME
            pending_attr_name = raw(token, xml)

        elseif k === TokenKinds.ATTR_VALUE
            val = _text_value(S, attr_value(token, xml), token.has_entities, convert_text)
            name = _to(S, pending_attr_name)
            if decl_attrs !== nothing
                any(p -> first(p) == name, decl_attrs) && error("Duplicate attribute: $name")
                push!(decl_attrs, name => val)
            elseif !isempty(attrs_stack)
                any(p -> first(p) == name, last(attrs_stack)) && error("Duplicate attribute: $name")
                push!(last(attrs_stack), name => val)
            end

        elseif k === TokenKinds.XML_DECL_OPEN
            decl_attrs = Pair{S,S}[]

        elseif k === TokenKinds.XML_DECL_CLOSE
            a = isempty(decl_attrs) ? nothing : decl_attrs
            push!(last(children_stack), Node{S}(Declaration, nothing, a, nothing, nothing))
            decl_attrs = nothing

        elseif k === TokenKinds.COMMENT_CONTENT
            push!(last(children_stack), Node{S}(Comment, nothing, nothing, _to(S, raw(token, xml)), nothing))

        elseif k === TokenKinds.CDATA_CONTENT
            push!(last(children_stack), Node{S}(CData, nothing, nothing, _to(S, raw(token, xml)), nothing))

        elseif k === TokenKinds.DOCTYPE_CONTENT
            push!(last(children_stack), Node{S}(DTD, nothing, nothing, _to(S, lstrip(raw(token, xml))), nothing))

        elseif k === TokenKinds.PI_OPEN
            pending_pi_tag = pi_target(token, xml)
            pending_pi_value = nothing

        elseif k === TokenKinds.PI_CONTENT
            content = strip(raw(token, xml))
            pending_pi_value = isempty(content) ? nothing : _to(S, content)

        elseif k === TokenKinds.PI_CLOSE
            push!(last(children_stack), Node{S}(ProcessingInstruction, _to(S, pending_pi_tag), nothing, pending_pi_value, nothing))
        end
    end

    !isempty(tags) && error("Unclosed tags: $(join(tags, ", "))")
    doc_children = only(children_stack)
    Node{S}(Document, nothing, nothing, nothing, isempty(doc_children) ? nothing : doc_children)
end

#-----------------------------------------------------------------------------# h (HTML/XML element builder)
"""
    h(tag, children...; attrs...)
    h.tag(children...; attrs...)

Convenience constructor for `Element` nodes.

    h("div", "hello"; class="main")  # <div class="main">hello</div>
    h.div("hello"; class="main")     # same thing
"""
function h(tag::Union{Symbol, AbstractString}, children...; attrs...)
    t = String(tag)
    a = Pair{String,String}[String(k) => String(v) for (k, v) in pairs(attrs)]
    c = Node{String}[_to_node(x) for x in children]
    Node{String}(Element, t, a, nothing, c)
end

Base.getproperty(::typeof(h), tag::Symbol) = h(tag)

function (o::Node)(args...; attrs...)
    o.nodetype === Element || error("Only Element nodes are callable.")
    old_children = something(o.children, ())
    old_attrs = isnothing(o.attributes) ? () : (Symbol(k) => v for (k, v) in o.attributes)
    h(o.tag, old_children..., args...; old_attrs..., attrs...)
end

#-----------------------------------------------------------------------------# DTD parsing
struct ElementDecl
    name::String
    content::String  # "EMPTY", "ANY", or content model like "(#PCDATA)" or "(a,b,c)*"
end

struct AttDecl
    element::String
    name::String
    type::String     # "CDATA", "ID", "(val1|val2)", "NOTATION (a|b)", etc.
    default::String  # "#REQUIRED", "#IMPLIED", "#FIXED \"val\"", or "\"val\""
end

struct EntityDecl
    name::String
    value::Union{Nothing, String}       # replacement text (internal entities)
    external_id::Union{Nothing, String} # "SYSTEM \"uri\"" or "PUBLIC \"pubid\" \"uri\""
    parameter::Bool
end

struct NotationDecl
    name::String
    external_id::String
end

struct ParsedDTD
    root::String
    system_id::Union{Nothing, String}
    public_id::Union{Nothing, String}
    elements::Vector{ElementDecl}
    attributes::Vector{AttDecl}
    entities::Vector{EntityDecl}
    notations::Vector{NotationDecl}
end

# DTD parsing helpers — each returns (parsed_piece, new_pos) so calls compose.

# A byte that can appear in an XML Name (letters, digits, `_`, `-`, `.`, `:`).
@inline _dtd_is_name_char(c::Char) =
    ('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') ||
    c == '_' || c == '-' || c == '.' || c == ':'

# Advance past any whitespace.
function _dtd_skip_ws(s, pos)
    while pos <= ncodeunits(s) && isspace(s[pos])
        pos += 1
    end
    pos
end

# Read an XML Name token; errors if no name characters are present.
function _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    start = pos
    while pos <= ncodeunits(s) && _dtd_is_name_char(s[pos])
        pos += 1
    end
    start == pos && error("Expected name at position $pos in DTD")
    SubString(s, start, pos - 1), pos
end

# Read a `"..."` or `'...'` string and return the contents without the surrounding quotes.
function _dtd_read_quoted(s, pos)
    pos = _dtd_skip_ws(s, pos)
    q = s[pos]
    (q == '"' || q == '\'') || error("Expected quoted string at position $pos in DTD")
    pos += 1
    start = pos
    while pos <= ncodeunits(s) && s[pos] != q
        pos += 1
    end
    val = SubString(s, start, pos - 1)
    pos += 1
    val, pos
end

# Read a balanced parenthesized expression (e.g. `(a|b|(c,d))`), returning the full
# substring including the outer `(` and `)`. Skips over quoted strings inside.
function _dtd_read_parens(s, pos)
    pos = _dtd_skip_ws(s, pos)
    s[pos] == '(' || error("Expected '(' at position $pos in DTD")
    depth = 1
    start = pos
    pos += 1
    while pos <= ncodeunits(s) && depth > 0
        c = s[pos]
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == '"' || c == '\''
            pos += 1
            while pos <= ncodeunits(s) && s[pos] != c
                pos += 1
            end
        end
        pos += 1
    end
    SubString(s, start, pos - 1), pos
end

# Advance past the next `>` that terminates a markup declaration, ignoring `>` inside
# quoted strings.
function _dtd_skip_to_close(s, pos)
    while pos <= ncodeunits(s) && s[pos] != '>'
        c = s[pos]
        if c == '"' || c == '\''
            pos += 1
            while pos <= ncodeunits(s) && s[pos] != c
                pos += 1
            end
        end
        pos += 1
    end
    pos <= ncodeunits(s) ? pos + 1 : pos
end

# Parse `<!ELEMENT name content>` — content is either a name (EMPTY/ANY) or a parens
# group with an optional `*`/`+`/`?` quantifier appended.
function _dtd_parse_element(s, pos)
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    if s[pos] == '('
        content, pos = _dtd_read_parens(s, pos)
        if pos <= ncodeunits(s) && s[pos] in ('*', '+', '?')
            content = string(content, s[pos])
            pos += 1
        end
    else
        content, pos = _dtd_read_name(s, pos)
    end
    pos = _dtd_skip_to_close(s, pos)
    ElementDecl(String(name), String(content)), pos
end

# Parse `<!ATTLIST element name type default ...>` — emits one AttDecl per attribute.
function _dtd_parse_attlist(s, pos)
    element, pos = _dtd_read_name(s, pos)
    atts = AttDecl[]
    while true
        pos = _dtd_skip_ws(s, pos)
        (pos > ncodeunits(s) || s[pos] == '>') && break

        name, pos = _dtd_read_name(s, pos)
        pos = _dtd_skip_ws(s, pos)

        # Attribute type
        if s[pos] == '('
            atype, pos = _dtd_read_parens(s, pos)
        else
            atype, pos = _dtd_read_name(s, pos)
            if atype == "NOTATION"
                pos = _dtd_skip_ws(s, pos)
                parens, pos = _dtd_read_parens(s, pos)
                atype = string("NOTATION ", parens)
            end
        end
        pos = _dtd_skip_ws(s, pos)

        # Default declaration
        if s[pos] == '#'
            pos += 1
            keyword, pos = _dtd_read_name(s, pos)
            if keyword == "FIXED"
                pos = _dtd_skip_ws(s, pos)
                val, pos = _dtd_read_quoted(s, pos)
                default = string("#FIXED \"", val, "\"")
            else
                default = string("#", keyword)
            end
        elseif s[pos] == '"' || s[pos] == '\''
            val, pos = _dtd_read_quoted(s, pos)
            default = string("\"", val, "\"")
        else
            error("Expected default declaration at position $pos in DTD")
        end
        push!(atts, AttDecl(String(element), String(name), String(atype), default))
    end
    pos <= ncodeunits(s) && s[pos] == '>' && (pos += 1)
    atts, pos
end

# Parse `<!ENTITY [%] name "value">` or `<!ENTITY name SYSTEM/PUBLIC ...>`. `%` marks a
# parameter entity (referenced as `%name;` in DTDs only).
function _dtd_parse_entity(s, pos)
    pos = _dtd_skip_ws(s, pos)
    parameter = false
    if pos <= ncodeunits(s) && s[pos] == '%'
        parameter = true
        pos += 1
    end
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)

    value = nothing
    external_id = nothing
    if s[pos] == '"' || s[pos] == '\''
        v, pos = _dtd_read_quoted(s, pos)
        value = String(v)
    else
        keyword, pos = _dtd_read_name(s, pos)
        pos = _dtd_skip_ws(s, pos)
        if keyword == "SYSTEM"
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("SYSTEM \"", uri, "\"")
        elseif keyword == "PUBLIC"
            pubid, pos = _dtd_read_quoted(s, pos)
            pos = _dtd_skip_ws(s, pos)
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("PUBLIC \"", pubid, "\" \"", uri, "\"")
        else
            error("Expected SYSTEM, PUBLIC, or quoted value in ENTITY declaration")
        end
    end
    pos = _dtd_skip_to_close(s, pos)
    EntityDecl(String(name), value, external_id, parameter), pos
end

# Parse `<!NOTATION name SYSTEM "uri">` / `<!NOTATION name PUBLIC "pubid" ["uri"]>`.
function _dtd_parse_notation(s, pos)
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    keyword, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    if keyword == "SYSTEM"
        uri, pos = _dtd_read_quoted(s, pos)
        external_id = string("SYSTEM \"", uri, "\"")
    elseif keyword == "PUBLIC"
        pubid, pos = _dtd_read_quoted(s, pos)
        pos = _dtd_skip_ws(s, pos)
        if pos <= ncodeunits(s) && (s[pos] == '"' || s[pos] == '\'')
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("PUBLIC \"", pubid, "\" \"", uri, "\"")
        else
            external_id = string("PUBLIC \"", pubid, "\"")
        end
    else
        error("Expected SYSTEM or PUBLIC in NOTATION declaration")
    end
    pos = _dtd_skip_to_close(s, pos)
    NotationDecl(String(name), external_id), pos
end

"""
    parse_dtd(value::AbstractString) -> ParsedDTD
    parse_dtd(node::Node) -> ParsedDTD

Parse a DTD value string (from a `DTD` node) into structured declarations.
"""
function parse_dtd(value::AbstractString)
    s = String(value)
    pos = 1

    root, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)

    # External ID
    system_id = nothing
    public_id = nothing
    if pos <= ncodeunits(s) && _dtd_is_name_char(s[pos])
        keyword, kpos = _dtd_read_name(s, pos)
        if keyword == "SYSTEM"
            pos = kpos
            uri, pos = _dtd_read_quoted(s, pos)
            system_id = String(uri)
        elseif keyword == "PUBLIC"
            pos = kpos
            pubid, pos = _dtd_read_quoted(s, pos)
            public_id = String(pubid)
            pos = _dtd_skip_ws(s, pos)
            if pos <= ncodeunits(s) && (s[pos] == '"' || s[pos] == '\'')
                uri, pos = _dtd_read_quoted(s, pos)
                system_id = String(uri)
            end
        end
    end

    elements = ElementDecl[]
    attributes = AttDecl[]
    entities = EntityDecl[]
    notations = NotationDecl[]

    # Internal subset
    pos = _dtd_skip_ws(s, pos)
    if pos <= ncodeunits(s) && s[pos] == '['
        pos += 1
        while pos <= ncodeunits(s)
            pos = _dtd_skip_ws(s, pos)
            pos > ncodeunits(s) && break
            s[pos] == ']' && break

            rest = SubString(s, pos)
            if startswith(rest, "<!--")
                i = findnext("-->", s, pos + 4)
                isnothing(i) && error("Unterminated comment in DTD")
                pos = last(i) + 1
            elseif startswith(rest, "<?")
                i = findnext("?>", s, pos + 2)
                isnothing(i) && error("Unterminated PI in DTD")
                pos = last(i) + 1
            elseif startswith(rest, "<!ELEMENT")
                elem, pos = _dtd_parse_element(s, pos + 9)
                push!(elements, elem)
            elseif startswith(rest, "<!ATTLIST")
                atts, pos = _dtd_parse_attlist(s, pos + 9)
                append!(attributes, atts)
            elseif startswith(rest, "<!ENTITY")
                ent, pos = _dtd_parse_entity(s, pos + 8)
                push!(entities, ent)
            elseif startswith(rest, "<!NOTATION")
                not, pos = _dtd_parse_notation(s, pos + 10)
                push!(notations, not)
            elseif s[pos] == '%'
                i = findnext(';', s, pos + 1)
                isnothing(i) && error("Unterminated parameter entity reference in DTD")
                pos = i + 1
            else
                pos += 1
            end
        end
    end

    ParsedDTD(String(root), system_id, public_id, elements, attributes, entities, notations)
end

function parse_dtd(node::Node)
    node.nodetype === DTD || error("parse_dtd requires a DTD node.")
    parse_dtd(node.value)
end

#-----------------------------------------------------------------------------# deprecations
Base.@deprecate_binding simplevalue simple_value false

# Removed types — informative errors
struct Raw
    Raw(args...; kw...) = error("""
        `XML.Raw` has been removed in XML.jl v0.4.
        Use `parse(str, Node)` or `read(filename, Node)` instead.
        The streaming Raw/LazyNode API has been replaced by a token-based parser.
        See `?XML.Node` for the new API.""")
end

# Removed functions — informative errors
const _REMOVED_LAZYNODE_MSG = """
    This function was part of the LazyNode API, which has been removed in XML.jl v0.4.
    Use `parse(str, Node)` to get a full DOM tree and navigate with `children`, `tag`,
    `attributes`, `value`, and integer indexing (e.g. `node[1]`)."""

for f in (:next, :prev)
    msg = "`XML.$f` has been removed. $_REMOVED_LAZYNODE_MSG"
    @eval function $f(o::Node)
        Base.depwarn($msg, $(QuoteNode(f)))
        error($msg)
    end
end

# 1-arg parent/depth were part of LazyNode API; 2-arg versions are defined above
const _PARENT_1ARG_MSG = "`XML.parent(node)` (single-argument) has been removed. $_REMOVED_LAZYNODE_MSG\n    Use `parent(child, root)` instead to search from a known root node."
function Base.parent(o::Node)
    Base.depwarn(_PARENT_1ARG_MSG, :parent)
    error(_PARENT_1ARG_MSG)
end

const _DEPTH_1ARG_MSG = "`XML.depth(node)` (single-argument) has been removed. $_REMOVED_LAZYNODE_MSG\n    Use `depth(child, root)` instead to search from a known root node."
function depth(o::Node)
    Base.depwarn(_DEPTH_1ARG_MSG, :depth)
    error(_DEPTH_1ARG_MSG)
end

function nodes_equal(a, b)
    msg = """`XML.nodes_equal` has been removed in XML.jl v0.4. Use `==` instead:
        a == b"""
    Base.depwarn(msg, :nodes_equal)
    error(msg)
end

function escape!(o::Node, warn::Bool=true)
    msg = """`XML.escape!` has been removed in XML.jl v0.4.
        Text is now escaped automatically during `XML.write`."""
    Base.depwarn(msg, :escape!)
    error(msg)
end

function unescape!(o::Node, warn::Bool=true)
    msg = """`XML.unescape!` has been removed in XML.jl v0.4.
        Text is now unescaped automatically during `parse`."""
    Base.depwarn(msg, :unescape!)
    error(msg)
end

end # module XML
