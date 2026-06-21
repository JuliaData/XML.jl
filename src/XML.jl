module XML

using Mmap
using OrderedCollections: OrderedDict

export
    # Core Types:
    Node, LazyNode,
    # Interface:
    children, nodetype, tag, attributes, value, is_simple, simplevalue, simple_value,
    # Extended Interface for LazyNode:
    parent, depth, next, prev, next!, prev!

#-----------------------------------------------------------------------------# escape/unescape
const escape_chars = ('&' => "&amp;", '<' => "&lt;", '>' => "&gt;", "'" => "&apos;", '"' => "&quot;")
function unescape(x::AbstractString)
    result = x
    for (pat, r) in reverse.(escape_chars)
        result = replace(result, pat => r)
    end
    return result
end
function escape(x::AbstractString)
    result = replace(x, r"&(?!amp;|quot;|apos;|gt;|lt;)" => "&amp;")
    for (pat, r) in escape_chars[2:end]
        result = replace(result, pat => r)
    end
    return result
end

#-----------------------------------------------------------------------------# NodeType
"""
    NodeType:
    - Document                  # prolog & root Element
    - DTD                       # <!DOCTYPE ...>
    - Declaration               # <?xml attributes... ?>
    - ProcessingInstruction    # <?NAME attributes... ?>
    - Comment                   # <!-- ... -->
    - CData                     # <![CDATA[...]]>
    - Element                   # <NAME attributes... > children... </NAME>
    - Text                      # text

NodeTypes can be used to construct XML.Nodes:

    Document(children...)
    DTD(value)
    Declaration(; attributes)
    ProcessingInstruction(tag, attributes)
    Comment(text)
    CData(text)
    Element(tag, children...; attributes)
    Text(text)
"""
@enum(NodeType, CData, Comment, Declaration, Document, DTD, Element, ProcessingInstruction, Text)


#-----------------------------------------------------------------------------# includes
include("raw.jl")
include("dtd.jl")

abstract type AbstractXMLNode end

#-----------------------------------------------------------------------------# LazyNode
"""
    LazyNode(file::AbstractString)
    LazyNode(data::XML.Raw)

A Lazy representation of an XML node.
"""
mutable struct LazyNode <: AbstractXMLNode
    raw::Raw
    tag::Union{Nothing, String}
    attributes::Union{Nothing, OrderedDict{String, String}}
    value::Union{Nothing, String}
end
LazyNode(raw::Raw) = LazyNode(raw, nothing, nothing, nothing)

function Base.getproperty(o::LazyNode, x::Symbol)
    x === :raw && return getfield(o, :raw)
    x === :nodetype && return nodetype(o.raw)
    x === :tag && return isnothing(getfield(o, x)) ? setfield!(o, x, tag(o.raw)) : getfield(o, x)
    x === :attributes && return isnothing(getfield(o, x)) ? setfield!(o, x, attributes(o.raw)) : getfield(o, x)
    x === :value && return isnothing(getfield(o, x)) ? setfield!(o, x, value(o.raw)) : getfield(o, x)
    x === :depth && return depth(o.raw)
    x === :children && return LazyNode.(children(o.raw))
    error("type LazyNode has no field $(x)")
end
Base.propertynames(o::LazyNode) = (:raw, :nodetype, :tag, :attributes, :value, :depth, :children)

Base.show(io::IO, o::LazyNode) = _show_node(io, o)

Base.read(io::IO, ::Type{LazyNode}) = LazyNode(read(io, Raw))
Base.read(filename::AbstractString, ::Type{LazyNode}) = LazyNode(read(filename, Raw))
Base.parse(x::AbstractString, ::Type{LazyNode}) = LazyNode(parse(x, Raw))

children(o::LazyNode) = LazyNode.(children(o.raw))
parent(o::LazyNode) = LazyNode(parent(o.raw))
depth(o::LazyNode) = depth(o.raw)

Base.IteratorSize(::Type{LazyNode}) = Base.SizeUnknown()
Base.eltype(::Type{LazyNode}) = LazyNode

function Base.iterate(o::LazyNode, state=o)
    n = next(state)
    return isnothing(n) ? nothing : (n, n)
end

function next(o::LazyNode)
    n = next(o.raw)
    isnothing(n) && return nothing
    n.type === RawElementClose ? next(LazyNode(n)) : LazyNode(n)
end
function prev(o::LazyNode)
    n = prev(o.raw)
    isnothing(n) && return nothing
    n.type === RawElementClose ? prev(LazyNode(n)) : LazyNode(n)
end

"""
    next!(o::LazyNode) -> LazyNode | Nothing

In-place variant of [`next`](@ref): advance `o` to the next node in
document order by mutating its fields. Returns `o` (now repositioned)
or `nothing` if the end of the document has been reached.

Functionally equivalent to `o = next(o)` but avoids allocating a fresh
`LazyNode` per traversal step. Tight loops that walk a large document
— for instance a downstream package extracting all `Placemark`
elements from a 50 MiB KML — can trade their per-step `LazyNode`
allocations for a single reused object.

The trade-off is **aliasing**: `o` is the same object after each call,
so callers must NOT retain references to a previous position (e.g. by
pushing `o` into a collection) — those references would silently track
the new position instead. If you need to keep a snapshot, copy the
raw descriptor with `LazyNode(o.raw)`.
"""
function next!(o::LazyNode)
    n = next(o.raw)
    isnothing(n) && return nothing
    while n !== nothing && n.type === RawElementClose
        n = next(n)
    end
    isnothing(n) && return nothing
    setfield!(o, :raw, n)
    setfield!(o, :tag, nothing)
    setfield!(o, :attributes, nothing)
    setfield!(o, :value, nothing)
    return o
end

"""
    prev!(o::LazyNode) -> LazyNode | Nothing

In-place reverse counterpart of [`next!`](@ref); see that method's
docstring for the aliasing caveat.
"""
function prev!(o::LazyNode)
    n = prev(o.raw)
    isnothing(n) && return nothing
    while n !== nothing && n.type === RawElementClose
        n = prev(n)
    end
    isnothing(n) && return nothing
    setfield!(o, :raw, n)
    setfield!(o, :tag, nothing)
    setfield!(o, :attributes, nothing)
    setfield!(o, :value, nothing)
    return o
end

#-----------------------------------------------------------------------------# Node
"""
    Node(nodetype, tag, attributes, value, children)
    Node(node::Node; kw...)  # copy node with keyword overrides
    Node(node::LazyNode)  # un-lazy the LazyNode

A representation of an XML DOM node.  For simpler construction, use `(::NodeType)(args...)`
"""
struct Node <: AbstractXMLNode
    nodetype::NodeType
    tag::Union{Nothing, String}
    attributes::Union{Nothing, OrderedDict{String, String}}
    value::Union{Nothing, String}
    children::Union{Nothing, Vector{Node}}

    function Node(nodetype::NodeType, tag=nothing, attributes=nothing, value=nothing, children=nothing)
        new(nodetype,
            isnothing(tag) ? nothing : string(tag),
            isnothing(attributes) ? nothing : OrderedDict(string(k) => string(v) for (k, v) in pairs(attributes)),
            isnothing(value) ? nothing : string(value),
            isnothing(children) ? nothing :
                children isa Node ? [children] :
                children isa Vector{Node} ? children :
                children isa Vector ? map(Node, children) :
                children isa Tuple ? map(Node, collect(children)) :
                [Node(children)]
        )
    end
end

function Node(o::Node, x...; kw...)
    attrs = !isnothing(kw) ?
        merge(
            OrderedDict(string(k) => string(v) for (k, v) in pairs(kw)),
            isnothing(o.attributes) ? OrderedDict{String,String}() : o.attributes
        ) :
        o.attributes
    children = isempty(x) ? o.children : vcat(isnothing(o.children) ? [] : o.children, collect(x))
    Node(o.nodetype, o.tag, attrs, o.value, children)
end

function Node(node::LazyNode)
    nodetype = node.nodetype
    tag = node.tag
    attributes = node.attributes
    value = node.value
    c = XML.children(node)
    Node(nodetype, tag, attributes, value, isempty(c) ? nothing : map(Node, c))
end

Node(data::Raw) = Node(LazyNode(data))

# Anything that's not Vector{UInt8} or a (Lazy)Node is converted to a Text Node
Node(x) = Node(Text, nothing, nothing, string(x), nothing)

h(tag::Union{Symbol, String}, children...; kw...) = Node(Element, tag, kw, nothing, children)
Base.getproperty(::typeof(h), tag::Symbol) = h(tag)
(o::Node)(children...; kw...) = Node(o, Node.(children)...; kw...)

# NOT in-place for Text Nodes
function escape!(o::Node, warn::Bool=true)
    if o.nodetype == Text
        warn && @warn "escape!() called on a Text Node creates a new node."
        return Text(escape(o.value))
    end
    isnothing(o.children) && return o
    map!(x -> escape!(x, false), o.children, o.children)
    o
end
function unescape!(o::Node, warn::Bool=true)
    if o.nodetype == Text
        warn && @warn "unescape!() called on a Text Node creates a new node."
        return Text(unescape(o.value))
    end
    isnothing(o.children) && return o
    map!(x -> unescape!(x, false), o.children, o.children)
    o
end


Base.read(filename::AbstractString, ::Type{Node}) = Node(read(filename, Raw))
Base.read(io::IO, ::Type{Node}) = Node(read(io, Raw))
Base.parse(x::AbstractString, ::Type{Node}) = Node(parse(x, Raw))

Base.setindex!(o::Node, val, i::Integer) = o.children[i] = Node(val)
Base.push!(a::Node, b::Node) = push!(a.children, b)
Base.pushfirst!(a::Node, b::Node) = pushfirst!(a.children, b)

Base.setindex!(o::Node, val, key::AbstractString) = (o.attributes[key] = string(val))
Base.getindex(o::Node, val::AbstractString) = o.attributes[val]
Base.haskey(o::Node, key::AbstractString) = isnothing(o.attributes) ? false : haskey(o.attributes, key)
Base.keys(o::Node) = isnothing(o.attributes) ? () : keys(o.attributes)

Base.show(io::IO, o::Node) = _show_node(io, o)

#-----------------------------------------------------------------------------# Node Constructors
function (T::NodeType)(args...; attr...)
    if T === Document
        !isempty(attr) && error("Document nodes do not have attributes.")
        Node(T, nothing, nothing, nothing, args)
    elseif T === DTD
        !isempty(attr) && error("DTD nodes only accept a value.")
        length(args) > 1 && error("DTD nodes only accept a value.")
        Node(T, nothing, nothing, only(args))
    elseif T === Declaration
        !isempty(args) && error("Declaration nodes only accept attributes")
        Node(T, nothing, attr)
    elseif T === ProcessingInstruction
        length(args) == 1 || error("ProcessingInstruction nodes require a tag and attributes.")
        Node(T, only(args), attr)
    elseif T === Comment
        !isempty(attr) && error("Comment nodes do not have attributes.")
        length(args) > 1 && error("Comment nodes only accept a single input.")
        Node(T, nothing, nothing, only(args))
    elseif T === CData
        !isempty(attr) && error("CData nodes do not have attributes.")
        length(args) > 1 && error("CData nodes only accept a single input.")
        Node(T, nothing, nothing, only(args))
    elseif T === Text
        !isempty(attr) && error("Text nodes do not have attributes.")
        length(args) > 1 && error("Text nodes only accept a single input.")
        Node(T, nothing, nothing, only(args))
    elseif T === Element
        tag = first(args)
        Node(T, tag, attr, nothing, args[2:end])
    else
        error("Unreachable reached while trying to create a Node via (::NodeType)(args...; kw...).")
    end
end

#-----------------------------------------------------------------------------# !!! common !!!
# Everything below here is common to all data structures


#-----------------------------------------------------------------------------# interface fallbacks
nodetype(o) = o.nodetype
tag(o) = o.tag
attributes(o) = o.attributes
value(o) = o.value
children(o::T) where {T} = isnothing(o.children) ? () : o.children

depth(o) = missing
parent(o) = missing
next(o) = missing
prev(o) = missing

is_simple(o) = nodetype(o) == Element && (isnothing(attributes(o)) || isempty(attributes(o))) &&
    length(children(o)) == 1 && nodetype(only(o)) in (Text, CData)

simple_value(o) = is_simple(o) ? value(only(o)) : error("`XML.simple_value` is only defined for simple nodes.")

Base.@deprecate_binding simplevalue simple_value

#-----------------------------------------------------------------------------# nodes_equal
function nodes_equal(a, b)
    out = XML.tag(a) == XML.tag(b)
    out &= XML.nodetype(a) == XML.nodetype(b)
    out &= XML.attributes(a) == XML.attributes(b)
    out &= XML.value(a) == XML.value(b)
    out &= length(XML.children(a)) == length(XML.children(b))
    out &= all(nodes_equal(ai, bi) for (ai,bi) in zip(XML.children(a), XML.children(b)))
    return out
end

Base.:(==)(a::AbstractXMLNode, b::AbstractXMLNode) = nodes_equal(a, b)

#-----------------------------------------------------------------------------# parse
Base.parse(::Type{T}, str::AbstractString) where {T <: AbstractXMLNode} = parse(str, T)

#-----------------------------------------------------------------------------# indexing
Base.getindex(o::Union{Raw, AbstractXMLNode}) = o
Base.getindex(o::Union{Raw, AbstractXMLNode}, i::Integer) = children(o)[i]
Base.getindex(o::Union{Raw, AbstractXMLNode}, ::Colon) = children(o)
Base.lastindex(o::Union{Raw, AbstractXMLNode}) = lastindex(children(o))

Base.only(o::Union{Raw, AbstractXMLNode}) = only(children(o))

Base.length(o::AbstractXMLNode) = length(children(o))

#-----------------------------------------------------------------------------# printing
function _show_node(io::IO, o)
    printstyled(io, typeof(o), ' '; color=:light_black)
    !ismissing(depth(o)) && printstyled(io, "(depth=", depth(o), ") ", color=:light_black)
    printstyled(io, nodetype(o), ; color=:light_green)
    if o.nodetype === Text
        printstyled(io, ' ', repr(value(o)))
    elseif o.nodetype === Element
        printstyled(io, " <", tag(o), color=:light_cyan)
        _print_attrs(io, o; color=:light_yellow)
        printstyled(io, '>', color=:light_cyan)
        _print_n_children(io, o)
    elseif o.nodetype === DTD
        printstyled(io, " <!DOCTYPE "; color=:light_cyan)
        printstyled(io, value(o), color=:light_black)
        printstyled(io, '>', color=:light_cyan)
    elseif o.nodetype === Declaration
        printstyled(io, " <?xml", color=:light_cyan)
        _print_attrs(io, o; color=:light_yellow)
        printstyled(io, "?>", color=:light_cyan)
    elseif o.nodetype === ProcessingInstruction
        printstyled(io, " <?", tag(o), color=:light_cyan)
        _print_attrs(io, o; color=:light_yellow)
        printstyled(io, "?>", color=:light_cyan)
    elseif o.nodetype === Comment
        printstyled(io, " <!--", color=:light_cyan)
        printstyled(io, value(o), color=:light_black)
        printstyled(io, "-->", color=:light_cyan)
    elseif o.nodetype === CData
        printstyled(io, " <![CDATA[", color=:light_cyan)
        printstyled(io, value(o), color=:light_black)
        printstyled(io, "]]>", color=:light_cyan)
    elseif o.nodetype === Document
        _print_n_children(io, o)
    elseif o.nodetype === UNKNOWN
        printstyled(io, "Unknown", color=:light_cyan)
        _print_n_children(io, o)
    else
        error("Unreachable reached")
    end
end

function _print_attrs(io::IO, o; color=:normal)
    attr = attributes(o)
    isnothing(attr) && return nothing
    for (k,v) in attr
        # printstyled(io, ' ', k, '=', '"', v, '"'; color)
        print(io, ' ', k, '=', '"', v, '"')
    end
end
function _print_n_children(io::IO, o::Node)
    n = length(children(o))
    text = n == 0 ? "" : n == 1 ? " (1 child)" : " ($n children)"
    printstyled(io, text, color=:light_black)
end
_print_n_children(io::IO, o) = nothing

#-----------------------------------------------------------------------------# write_xml
write(x; kw...) = (io = IOBuffer(); write(io, x; kw...); String(take!(io)))

write(filename::AbstractString, x; kw...) = open(io -> write(io, x; kw...), filename, "w")

function write(io::IO, x, ctx::Vector{Bool}=[false]; indentsize::Int=2, depth::Int=1)
    indent = ' ' ^ indentsize
    nodetype = XML.nodetype(x)
    tag = XML.tag(x)
    value = XML.value(x)
    children = XML.children(x)

    padding = indent ^ max(0, depth - 1)
    !ctx[end] && print(io, padding)

    if nodetype === Text
        print(io, value)

    elseif nodetype === Element
        push!(ctx, ctx[end])
        update_ctx!(ctx, x)
        print(io, '<', tag)
        _print_attrs(io, x)
        print(io, isempty(children) ? '/' : "", '>')
        if !isempty(children)
            if length(children) == 1 && XML.nodetype(only(children)) === Text
                write(io, only(children), ctx; indentsize=0)
                print(io, "</", tag, '>')
            else
                !ctx[end] && println(io)
                foreach(children) do child
                    write(io, child, ctx; indentsize, depth=depth + 1)
                    !ctx[end] && println(io)
                end
                print(io, !ctx[end] ? padding : "", "</", tag, '>')
            end
        end
        pop!(ctx)

    elseif nodetype === DTD
        print(io, "<!DOCTYPE ", value, '>')

    elseif nodetype === Declaration
        print(io, "<?xml")
        _print_attrs(io, x)
        print(io, "?>")

    elseif nodetype === ProcessingInstruction
        print(io, "<?", tag)
        _print_attrs(io, x)
        print(io, "?>")

    elseif nodetype === Comment
        print(io, "<!--", value, "-->")

    elseif nodetype === CData
        print(io, "<![CDATA[", value, "]]>")

    elseif nodetype === Document
        foreach(children) do child
            write(io, child, ctx; indentsize)
            !ctx[end] && println(io)
        end

    else
        error("Unreachable case reached during XML.write")
    end

end

end # module XML
