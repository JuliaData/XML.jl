module XMLAbstractTreesExt

using XML: XML, Node, LazyNode, NodeType, Element, Text, CData, Comment,
    Declaration, DTD, Document, ProcessingInstruction,
    nodetype, tag, value, attributes
import AbstractTrees

#-----------------------------------------------------------------------------# children
AbstractTrees.children(n::Node) = XML.children(n)
AbstractTrees.children(n::LazyNode) = XML.children(n)

#-----------------------------------------------------------------------------# nodevalue
AbstractTrees.nodevalue(n::Node) = n
AbstractTrees.nodevalue(n::LazyNode) = n

#-----------------------------------------------------------------------------# printnode
# Single-line label for `print_tree`; mirrors the REPL `show` for each NodeType but
# without trailing child-count annotations (AbstractTrees draws the structure).
_printnode(io::IO, n::Union{Node, LazyNode}) = _printnode(io, n, nodetype(n))

function _printnode(io::IO, n, ::Val{Element})
    print(io, '<', tag(n))
    attrs = attributes(n)
    if !isnothing(attrs)
        for (k, v) in attrs
            print(io, ' ', k, '=', '"', v, '"')
        end
    end
    print(io, '>')
end

_printnode(io::IO, n, ::Val{Text})     = show(io, value(n))
_printnode(io::IO, n, ::Val{Comment})  = print(io, "<!--", value(n), "-->")
_printnode(io::IO, n, ::Val{CData})    = print(io, "<![CDATA[", value(n), "]]>")
_printnode(io::IO, n, ::Val{DTD})      = print(io, "<!DOCTYPE ", value(n), '>')

function _printnode(io::IO, n, ::Val{Declaration})
    print(io, "<?xml")
    attrs = attributes(n)
    if !isnothing(attrs)
        for (k, v) in attrs
            print(io, ' ', k, '=', '"', v, '"')
        end
    end
    print(io, "?>")
end

function _printnode(io::IO, n, ::Val{ProcessingInstruction})
    print(io, "<?", tag(n))
    v = value(n)
    !isnothing(v) && print(io, ' ', v)
    print(io, "?>")
end

_printnode(io::IO, n, ::Val{Document}) = print(io, "Document")

# Dispatch helper: avoid an Enum branch chain by tag-dispatching on Val{NodeType}.
_printnode(io::IO, n, nt::NodeType) = _printnode(io, n, Val(nt))

AbstractTrees.printnode(io::IO, n::Node)     = _printnode(io, n)
AbstractTrees.printnode(io::IO, n::LazyNode) = _printnode(io, n)

#-----------------------------------------------------------------------------# traits
AbstractTrees.NodeType(::Type{<:Node})     = AbstractTrees.HasNodeType()
AbstractTrees.NodeType(::Type{<:LazyNode}) = AbstractTrees.HasNodeType()
AbstractTrees.nodetype(::Type{N}) where {N <: Node}     = N
AbstractTrees.nodetype(::Type{L}) where {L <: LazyNode} = L

AbstractTrees.ChildIndexing(::Type{<:Node}) = AbstractTrees.IndexedChildren()

end # module
