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

include("node.jl")
include("xpath.jl")
include("lazynode.jl")
include("cursor.jl")
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
