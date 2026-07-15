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
    eachelement(node)

Lazy iterator over the child *elements* of `node`, skipping every other node type
(`Text`, `Comment`, `CData`, `ProcessingInstruction`, …). Since v0.4 preserves
inter-element whitespace, `children` on pretty-printed documents interleaves
whitespace `Text` nodes with elements — `eachelement` is the idiomatic way to
iterate the elements only. Works with both `Node` and `LazyNode`.

    for el in eachelement(node)
        # el isa Element node
    end

See also [`elements`](@ref).
"""
eachelement(node) = Iterators.filter(n -> nodetype(n) === Element, children(node))

"""
    elements(node) -> Vector

The child *elements* of `node` in document order — the collected counterpart of
[`eachelement`](@ref).
"""
elements(node) = collect(eachelement(node))

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

const _AMBIGUOUS_NODE_MSG = "ambiguous: the node matches multiple indistinguishable occurrences in the tree; use FlatNode for positional navigation."

"""
    parent(child::Node, root::Node) -> Node

Return the parent of `child` within the tree rooted at `root`.

Since `Node` does not store parent pointers, this performs a tree search from `root`.
Throws an error if `child` is not found or if `child === root`.

!!! warning "Value identity"
    `Node` is an immutable value type, so the search matches by value (`===`). In a tree
    containing several value-identical nodes (e.g. two empty `<item/>` elements), the
    occurrence the caller meant cannot be determined, and an error is raised instead of
    silently answering for the first match. The same applies to [`depth`](@ref),
    [`siblings`](@ref), and the XPath `..` axis. `FlatNode` navigates positionally and has
    no such ambiguity.
"""
function Base.parent(child::Node, root::Node)
    child === root && error("Root node has no parent.")
    acc = Node[]
    _find_parents!(acc, child, root)
    isempty(acc) && error("Node not found in tree.")
    length(acc) > 1 && error(_AMBIGUOUS_NODE_MSG)
    acc[1]
end

# Depth-first search for occurrences of `child` within `current`, collecting each
# occurrence's parent; stops after a second occurrence — one is a result, two is ambiguous.
function _find_parents!(acc::Vector{Node}, child::Node, current::Node)
    for c in children(current)
        if c === child
            push!(acc, current)
            length(acc) >= 2 && return acc
        end
        _find_parents!(acc, child, c)
        length(acc) >= 2 && return acc
    end
    acc
end

"""
    depth(child::Node, root::Node) -> Int

Return the depth of `child` within the tree rooted at `root` (root has depth 0).

Since `Node` does not store parent pointers, this performs a tree search from `root`.
Throws an error if `child` is not found in the tree, or if it matches several
value-identical occurrences (see the warning in [`parent`](@ref)).
"""
function depth(child::Node, root::Node)
    child === root && return 0
    acc = Int[]
    _find_depths!(acc, child, root, 0)
    isempty(acc) && error("Node not found in tree.")
    length(acc) > 1 && error(_AMBIGUOUS_NODE_MSG)
    acc[1]
end

# Depth-first search collecting the depth of each occurrence of `child` relative to
# `current` (children of `current` are at depth `d + 1`); stops after a second occurrence.
function _find_depths!(acc::Vector{Int}, child::Node, current::Node, d::Int)
    for c in children(current)
        if c === child
            push!(acc, d + 1)
            length(acc) >= 2 && return acc
        end
        _find_depths!(acc, child, c, d + 1)
        length(acc) >= 2 && return acc
    end
    acc
end

"""
    siblings(child::Node, root::Node) -> Vector{Node}

Return the siblings of `child` (other children of the same parent) within the tree rooted
at `root`.  The returned vector does not include `child` itself.

Throws an error if `child` is the root, is not found in the tree, or matches several
value-identical occurrences (see the warning in [`parent`](@ref)).
"""
function siblings(child::Node, root::Node)
    p = parent(child, root)
    [c for c in children(p) if c !== child]
end



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
# A valid XML 1.0 Name (§2.3): a NameStartChar followed by NameChars, using the same lenient
# per-character rule as the tokenizer (every non-ASCII char is accepted; the exact Unicode ranges
# are not enforced) — so a constructed node's name is one the parser would also accept and
# round-trip, rather than a string like "" or "1bad" that serializes to malformed XML.
_is_xml_name(s::AbstractString) = !isempty(s) && _is_name_start(first(s)) && all(_dtd_is_name_char, s)

function (T::NodeType)(args...; attrs...)
    S = String
    if T in (Text, Comment, CData, DTD)
        length(args) == 1 || error("$T nodes require exactly one value argument.")
        !isempty(attrs) && error("$T nodes do not accept attributes.")
        v = string(only(args))
        # A value containing its own close delimiter is un-representable: write would emit XML that
        # re-parses split into multiple nodes. (DTD is excluded — its internal subset legitimately
        # contains '>'.)
        T === Comment && occursin("-->", v) && error("Comment content cannot contain \"-->\": $(repr(v))")
        T === CData && occursin("]]>", v) && error("CData content cannot contain \"]]>\": $(repr(v))")
        Node{S}(T, nothing, nothing, v, nothing)
    elseif T === Element
        isempty(args) && error("Element nodes require at least a tag.")
        t = string(first(args))
        _is_xml_name(t) || error("invalid XML element name $(repr(t)): must be an XML 1.0 Name")
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
        _is_xml_name(t) || error("invalid XML processing-instruction target $(repr(t)): must be an XML 1.0 Name")
        v = length(args) == 2 ? string(args[2]) : nothing
        v !== nothing && occursin("?>", v) && error("ProcessingInstruction content cannot contain \"?>\": $(repr(v))")
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
# Attribute equality is order-insensitive per XML spec; an absent (`nothing`) attribute
# set equals an empty one. Containers differ per reader (Attributes, lazy iterators,
# decoded pairs), so collect to pairs before comparing; keys are unique by
# well-formedness, which makes the pairwise membership test sound.
function _attrs_eq(a, b)
    va = isnothing(a) ? nothing : [k => v for (k, v) in a]
    vb = isnothing(b) ? nothing : [k => v for (k, v) in b]
    a_empty = isnothing(va) || isempty(va)
    b_empty = isnothing(vb) || isempty(vb)
    a_empty && b_empty && return true
    (a_empty || b_empty) && return false
    length(va) == length(vb) || return false
    for p in va
        any(==(p), vb) || return false
    end
    true
end

# Structural equality and hash over the generic accessor surface (nodetype/tag/
# attributes/value/children), shared by every tree reader and the cross-reader case —
# the `Base` bindings live in identity.jl, after all reader types exist. Attribute order
# is insignificant; child order is significant; absent (`nothing`) attributes/children
# compare and hash like empty ones.
function _structural_eq(a, b)
    nodetype(a) === nodetype(b) || return false
    tag(a) == tag(b) || return false
    _attrs_eq(attributes(a), attributes(b)) || return false
    value(a) == value(b) || return false
    ca, cb = children(a), children(b)
    sa, sb = iterate(ca), iterate(cb)
    while sa !== nothing && sb !== nothing
        _structural_eq(sa[1], sb[1]) || return false
        sa, sb = iterate(ca, sa[2]), iterate(cb, sb[2])
    end
    sa === nothing && sb === nothing
end

# Commutative ⊻ over attribute pair hashes mirrors `_attrs_eq`'s order-insensitivity;
# duplicate keys are excluded by well-formedness.
function _structural_hash(n, h::UInt)
    h = hash(nodetype(n), h)
    h = hash(tag(n), h)
    ha = UInt(0)
    a = attributes(n)
    if !isnothing(a)
        for kv in a
            ha ⊻= hash(kv)
        end
    end
    h = hash(ha, h)
    h = hash(value(n), h)
    for c in children(n)
        h = _structural_hash(c, h)
    end
    h
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

