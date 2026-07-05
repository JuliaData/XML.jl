module XML

export
    Node, LazyNode, NodeType, Attributes,
    CData, Comment, Declaration, Document, DTD, Element, ProcessingInstruction, Text,
    nodetype, tag, attributes, value, children, children!, eachchildnode, eachattribute,
    eachelement, elements,
    foreach_attr,
    is_simple, simple_value, is_simple_value, sourcetext,
    depth, siblings,
    Cursor, next!, for_each_child, @for_each_child, skip_element!, eof,
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

# One regex matching any supported reference: the five predefined entities plus a decimal
# or hex numeric character reference. `unescape` applies it in a SINGLE `replace` pass, so a
# reference that resolves to '&' (e.g. `&#38;`) is never re-scanned as the start of a new
# entity — `replace` substitutes left-to-right over the original string and never re-reads
# what it emitted.
const _ENTITY_RE = r"&(?:amp|lt|gt|apos|quot|#[0-9]+|#[xX][0-9a-fA-F]+);"

function _unescape_entity(m::AbstractString)
    m == "&amp;"  && return "&"
    m == "&lt;"   && return "<"
    m == "&gt;"   && return ">"
    m == "&apos;" && return "'"
    m == "&quot;" && return "\""
    return _unescape_charref(m)   # numeric ref (the only remaining alternative); verbatim if out of range
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
    replace(s, _ENTITY_RE => _unescape_entity)
end

function unescape(x::SubString{String})
    occursin('&', x) || return x
    replace(String(x), _ENTITY_RE => _unescape_entity)
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

"""
    parent(child::Node, root::Node) -> Node

Return the parent of `child` within the tree rooted at `root`.

Since `Node` does not store parent pointers, this performs a tree search from `root`.
Throws an error if `child` is not found or if `child === root`.

!!! warning "Value identity"
    `Node` is an immutable value type, so the search matches by structural equality (`===`). In a
    tree containing value-identical sibling nodes (e.g. two empty `<item/>` elements), this may
    return the parent of the *first* match rather than the specific node passed. The same applies to
    [`depth`](@ref), [`siblings`](@ref), and the XPath `..` axis. A path-based redesign is planned.
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

include("write.jl")
include("parse.jl")
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

include("dtd.jl")
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
