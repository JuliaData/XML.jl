#-----------------------------------------------------------------------------# Cursor
# Event-level StAX cursor: a SINGLE mutable wrapper advanced in place over the
# token stream (the cursor-based StAX layer from JuliaComputing/XML.jl#61).
#
# Design — orthogonal to the DOM (LazyNode) layer:
#   `Cursor` and `LazyNode` are SIBLINGS on the shared `XMLTokenizer`
#   foundation. The cursor's accessors rest on the token-layer primitives
#   (`tag_name`, `attr_value`, `pi_target`, `unescape`) — they NEVER call
#   LazyNode or its accessors. So changes to the DOM layer (lazynode.jl) do
#   not affect the cursor. The token→value logic is intentionally duplicated
#   from `value`/`attributes(::LazyNode)` rather than shared, to keep this
#   file purely additive; a later refactor can factor the common helpers into
#   the token layer if desired.
#
# Performance — closes the per-child `LazyNode` allocation gap by mutating one
# object instead of materializing a node per child visited (targets the
# `next!()`-DFS performance class).

const _CURSOR_XT = XMLTokenizer

mutable struct Cursor{S <: AbstractString}
    st::_CURSOR_XT.StatefulTokenizer{S}  # mutable token engine (advances in place)
    token::_CURSOR_XT.Token{S}           # opening/primary token of the current node
    nodetype::NodeType                   # current event kind
    depth::Int                           # current node's depth (root children = 1)
    enclosing::Int                       # open-element count (depth bookkeeping)
    done::Bool
end

"""
    Cursor(data::AbstractString)
    parse(Cursor, data::AbstractString)

A forward, in-place [`StAX`-style] pull cursor over the XML `data`. Advance it
with [`next!`](@ref); read the current position with [`nodetype`](@ref),
[`tag`](@ref), [`value`](@ref), [`attributes`](@ref), [`depth`](@ref).

The cursor is a single mutable object reused across the whole walk. See the
aliasing-contract note on [`next!`](@ref).
"""
function Cursor(data::S) where {S <: AbstractString}
    st = _CURSOR_XT.StatefulTokenizer(_CURSOR_XT.Tokenizer(data, 1))
    Cursor{S}(st, _CURSOR_XT.no_token(data), Document, 0, 0, false)
end
Base.parse(::Type{Cursor}, xml::AbstractString) = Cursor(String(xml))

@inline _data(c::Cursor) = c.st.t.data
# A fresh token stream positioned at the current node — mirrors LazyNode's
# `_lazy_tokenizer`, but built directly on the token layer (no LazyNode).
@inline _rescan(c::Cursor) = tokenize(_data(c), c.token.raw.offset + 1)

#-----------------------------------------------------------------------------# next!
"""
    next!(c::Cursor) -> Union{Cursor, Nothing}

Advance the cursor to the next node in document order (depth-first), mutating
it in place. Returns the cursor, or `nothing` at end of stream.

**Aliasing contract**: the cursor is ONE mutable object — any reference to it
always reflects its *current* position. Reading fields synchronously (inside
the loop body) is safe; to *retain* a position across further advances,
snapshot it (e.g. `LazyNode(c)`).
"""
@inline function next!(c::Cursor)
    c.done && return nothing
    K = _CURSOR_XT.TokenKinds
    while true
        r = iterate(c.st)                       # mutates c.st.state in place
        r === nothing && (c.done = true; return nothing)
        tok = r[1]
        k = tok.kind
        if k === K.OPEN_TAG                      # element start
            c.token = tok; c.nodetype = Element
            c.depth = c.enclosing + 1; c.enclosing += 1   # element node, then descend
            return c
        elseif k === K.CLOSE_TAG                 # </name> → ascend
            c.enclosing -= 1
        elseif k === K.SELF_CLOSE                # <tag/> already yielded at OPEN_TAG
            c.enclosing -= 1
        elseif k === K.TEXT
            c.token = tok; c.nodetype = Text; c.depth = c.enclosing + 1
            return c
        elseif k === K.CDATA_OPEN
            c.token = tok; c.nodetype = CData; c.depth = c.enclosing + 1
            _lazy_skip_until!(c.st, K.CDATA_CLOSE); return c
        elseif k === K.COMMENT_OPEN
            c.token = tok; c.nodetype = Comment; c.depth = c.enclosing + 1
            _lazy_skip_until!(c.st, K.COMMENT_CLOSE); return c
        elseif k === K.PI_OPEN
            c.token = tok; c.nodetype = ProcessingInstruction; c.depth = c.enclosing + 1
            _lazy_skip_until!(c.st, K.PI_CLOSE); return c
        elseif k === K.XML_DECL_OPEN
            c.token = tok; c.nodetype = Declaration; c.depth = c.enclosing + 1
            _lazy_skip_until!(c.st, K.XML_DECL_CLOSE); return c
        elseif k === K.DOCTYPE_OPEN
            c.token = tok; c.nodetype = DTD; c.depth = c.enclosing + 1
            _lazy_skip_until!(c.st, K.DOCTYPE_CLOSE); return c
        end
        # TAG_CLOSE (the `>` of open and close tags), ATTR_NAME, ATTR_VALUE,
        # and the *_CONTENT / *_CLOSE tokens consumed above are structural —
        # the loop skips them with no depth change.
    end
end

#-----------------------------------------------------------------------------# accessors
@inline nodetype(c::Cursor) = c.nodetype
@inline depth(c::Cursor)    = c.depth
@inline eof(c::Cursor)      = c.done

function tag(c::Cursor)
    nt = c.nodetype
    nt === Element                ? tag_name(c.token) :
    nt === ProcessingInstruction  ? pi_target(c.token) : nothing
end

# token-layer entity decode (inlined `_decode`; depends only on `unescape`).
# Returns Union{SubString,String} like `value(::LazyNode)` — the polymorphic
# return is inherent to the accessor; the residual boxing it causes is minor
# next to the per-token allocation that Phase 2 (bitstype Token) removes.
@inline _cursor_decode(tok) = tok.has_entities ? unescape(tok.raw) : tok.raw

function value(c::Cursor)
    nt = c.nodetype
    if nt === Text
        return _cursor_decode(c.token)
    elseif nt === Comment
        it = _rescan(c); iterate(it)            # COMMENT_OPEN
        return iterate(it)[1].raw
    elseif nt === CData
        it = _rescan(c); iterate(it)            # CDATA_OPEN
        return iterate(it)[1].raw
    elseif nt === DTD
        it = _rescan(c); iterate(it)            # DOCTYPE_OPEN
        return lstrip(iterate(it)[1].raw)
    elseif nt === ProcessingInstruction
        it = _rescan(c); iterate(it)            # PI_OPEN
        r = iterate(it)
        r === nothing && return nothing
        r[1].kind === _CURSOR_XT.TokenKinds.PI_CONTENT || return nothing
        content = strip(r[1].raw)
        return isempty(content) ? nothing : content
    end
    nothing
end

@inline _cursor_decode_attr(tok) =
    tok.has_entities ? unescape(attr_value(tok)) : attr_value(tok)
@inline _cursor_as_substring(s::SubString{String}) = s
@inline _cursor_as_substring(s::String) = SubString(s, 1, lastindex(s))

function attributes(c::Cursor)
    c.nodetype in (Element, Declaration) || return nothing
    it = _rescan(c); iterate(it)                # skip OPEN_TAG / XML_DECL_OPEN
    attrs = Pair{SubString{String}, SubString{String}}[]
    for tok in it
        tok.kind === _CURSOR_XT.TokenKinds.ATTR_NAME || break
        name = tok.raw
        r = iterate(it)
        r === nothing && break
        push!(attrs, name => _cursor_as_substring(_cursor_decode_attr(r[1])))
    end
    isempty(attrs) ? nothing : Attributes(attrs)
end

# Single-attribute read with no `Attributes` allocation.
function Base.get(c::Cursor, key::AbstractString, default)
    c.nodetype in (Element, Declaration) || return default
    it = _rescan(c); iterate(it)
    for tok in it
        tok.kind === _CURSOR_XT.TokenKinds.ATTR_NAME || return default
        if tok.raw == key
            r = iterate(it)
            r === nothing && return default
            return _cursor_decode_attr(r[1])
        else
            iterate(it)                         # skip value
        end
    end
    default
end

#-----------------------------------------------------------------------------# snapshot (bridge to DOM)
# The ONE place that references `LazyNode` — a one-way, optional bridge for
# storing the current position. The cursor's own operation never depends on it.
LazyNode(c::Cursor) = LazyNode(_data(c), c.token, c.nodetype)

#-----------------------------------------------------------------------------# traversal
"""
    for_each_child(f, c::Cursor)

Apply `f(c)` to each immediate child of the cursor's current node, advancing
`c` in place (a depth-tracked forward sweep). Deeper descendants are visited
but not passed to `f`. Read `c` synchronously inside `f` (aliasing contract).
"""
function for_each_child(f, c::Cursor)
    initial = c.depth
    target  = initial + 1
    while next!(c) !== nothing
        c.depth <= initial && break             # left the parent's subtree
        c.depth == target && f(c)
    end
    return c
end

# Pull-mode iterator surface → `for node in c … end`. The yielded value IS the
# cursor (aliasing contract).
function Base.iterate(c::Cursor, ::Nothing = nothing)
    next!(c) === nothing && return nothing
    (c, nothing)
end
Base.IteratorSize(::Type{<:Cursor}) = Base.SizeUnknown()
Base.eltype(::Type{Cursor{S}}) where {S} = Cursor{S}

function Base.show(io::IO, c::Cursor)
    print(io, "Cursor(", c.nodetype, " @ depth ", c.depth, c.done ? ", eof" : "", ")")
end
