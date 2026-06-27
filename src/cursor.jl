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
    token::_CURSOR_XT.Token              # opening/primary token of the current node (isbits)
    nodetype::NodeType                   # current event kind
    depth::Int                           # current node's depth (root children = 1)
    enclosing::Int                       # open-element count (depth bookkeeping)
    done::Bool
    held::Bool                           # peek flag: current node not yet consumed (see for_each_child)
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
    data = _drop_bom(data)   # a leading U+FEFF BOM char is an encoding signature, not content (§4.3.3)
    st = _CURSOR_XT.StatefulTokenizer(_CURSOR_XT.Tokenizer(data, 1))
    Cursor{S}(st, _CURSOR_XT.no_token(data), Document, 0, 0, false, false)
end
Base.parse(::Type{Cursor}, xml::AbstractString) = Cursor(String(xml))

"""
    Cursor(data::AbstractString, startpos::Integer)

A cursor whose token stream starts at byte position `startpos` in `data` instead
of the document start — for walking a subtree whose start offset is already known.
The first [`next!`](@ref) lands on whatever element begins at `startpos`, at depth
1, so [`for_each_child`](@ref) then iterates that element's immediate children and
auto-stops at its subtree boundary (the depth break). LazyNode-agnostic primitive.
"""
function Cursor(data::S, startpos::Integer) where {S <: AbstractString}
    st = _CURSOR_XT.StatefulTokenizer(_CURSOR_XT.Tokenizer(data, startpos))
    Cursor{S}(st, _CURSOR_XT.no_token(data), Document, 0, 0, false, false)
end

"""
    Cursor(node::LazyNode)

Convenience bridge: a cursor positioned to walk `node` and its subtree — the
inverse of the `LazyNode(c)` snapshot. Delegates to `Cursor(data, startpos)` with
`node`'s source string and start offset; it is the only place `Cursor` mentions
`LazyNode`, and it is an optional, removable convenience (a consumer that tracks
subtree start offsets directly can call the primitive `Cursor(data, startpos)`).
"""
Cursor(node::LazyNode) = Cursor(node.data, node.token.offset + 1)

@inline _data(c::Cursor) = c.st.t.data
# A fresh token stream positioned at the current node — mirrors LazyNode's
# `_lazy_tokenizer`, but built directly on the token layer (no LazyNode).
@inline _rescan(c::Cursor) = tokenize(_data(c), c.token.offset + 1)

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
    if c.held               # a node held by a child-iteration break — re-yield without advancing
        c.held = false
        return c
    end
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
    nt === Element                ? tag_name(c.token, _data(c)) :
    nt === ProcessingInstruction  ? pi_target(c.token, _data(c)) : nothing
end

# token-layer entity decode (inlined `_decode`; depends only on `unescape`).
# Returns Union{SubString,String} like `value(::LazyNode)` — the polymorphic
# return is inherent to the accessor; the residual boxing it causes is minor
# next to the per-token allocation that Phase 2 (bitstype Token) removes.
@inline _cursor_decode(tok, data) = tok.has_entities ? unescape(raw(tok, data)) : raw(tok, data)

function value(c::Cursor)
    nt = c.nodetype
    if nt === Text
        return _cursor_decode(c.token, _data(c))
    elseif nt === Comment
        it = _rescan(c); iterate(it)            # COMMENT_OPEN
        return raw(iterate(it)[1], _data(c))
    elseif nt === CData
        it = _rescan(c); iterate(it)            # CDATA_OPEN
        return raw(iterate(it)[1], _data(c))
    elseif nt === DTD
        it = _rescan(c); iterate(it)            # DOCTYPE_OPEN
        return lstrip(raw(iterate(it)[1], _data(c)))
    elseif nt === ProcessingInstruction
        it = _rescan(c); iterate(it)            # PI_OPEN
        r = iterate(it)
        r === nothing && return nothing
        r[1].kind === _CURSOR_XT.TokenKinds.PI_CONTENT || return nothing
        content = lstrip(raw(r[1], _data(c)))
        return isempty(content) ? nothing : content
    end
    nothing
end

@inline _cursor_decode_attr(tok, data) =
    tok.has_entities ? unescape(attr_value(tok, data)) : attr_value(tok, data)
@inline _cursor_as_substring(s::SubString{String}) = s
@inline _cursor_as_substring(s::String) = SubString(s, 1, lastindex(s))

function attributes(c::Cursor)
    c.nodetype in (Element, Declaration) || return nothing
    it = _rescan(c); iterate(it)                # skip OPEN_TAG / XML_DECL_OPEN
    attrs = Pair{SubString{String}, SubString{String}}[]
    for tok in it
        tok.kind === _CURSOR_XT.TokenKinds.ATTR_NAME || break
        name = raw(tok, _data(c))
        r = iterate(it)
        r === nothing && break
        push!(attrs, name => _cursor_as_substring(_cursor_decode_attr(r[1], _data(c))))
    end
    isempty(attrs) ? nothing : Attributes(attrs)
end

# Single-attribute read with no `Attributes` allocation.
function Base.get(c::Cursor, key::AbstractString, default)
    c.nodetype in (Element, Declaration) || return default
    it = _rescan(c); iterate(it)
    for tok in it
        tok.kind === _CURSOR_XT.TokenKinds.ATTR_NAME || return default
        if raw(tok, _data(c)) == key
            r = iterate(it)
            r === nothing && return default
            return _cursor_decode_attr(r[1], _data(c))
        else
            iterate(it)                         # skip value
        end
    end
    default
end

#-----------------------------------------------------------------------------# is_simple_value
# Cursor mirror of `is_simple_value(::LazyNode)`: combined predicate+accessor that
# returns the lone Text/CData value of the current element (or `nothing` if it has
# attributes / isn't a single-text element). Non-destructive — reads via `_rescan`,
# so the cursor position is unchanged (caller still advances with `for_each_child` /
# `skip_element!`). Lets hot paths read e.g. an XLSX `<v>` value with no LazyNode snapshot.
function is_simple_value(c::Cursor)
    c.nodetype === Element || return nothing
    it = _rescan(c)
    iterate(it)                                 # skip OPEN_TAG
    found_close = false
    for tok in it
        tok.kind === _CURSOR_XT.TokenKinds.TAG_CLOSE && (found_close = true; break)
        return nothing                          # has attributes / self-close / not simple
    end
    found_close || return nothing
    result = iterate(it)
    result === nothing && return nothing
    tok = result[1]
    if tok.kind === _CURSOR_XT.TokenKinds.TEXT
        nxt = iterate(it)
        (nxt === nothing || nxt[1].kind !== _CURSOR_XT.TokenKinds.CLOSE_TAG) && return nothing
        return _cursor_decode(tok, _data(c))
    elseif tok.kind === _CURSOR_XT.TokenKinds.CDATA_OPEN
        r = iterate(it)
        (r === nothing || r[1].kind !== _CURSOR_XT.TokenKinds.CDATA_CONTENT) && return nothing
        content = raw(r[1], _data(c))
        r = iterate(it)
        (r === nothing || r[1].kind !== _CURSOR_XT.TokenKinds.CDATA_CLOSE) && return nothing
        r = iterate(it)
        (r === nothing || r[1].kind !== _CURSOR_XT.TokenKinds.CLOSE_TAG) && return nothing
        return content
    end
    nothing
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

Nestable: calling `for_each_child` again inside `f` descends into that child's
own subtree and composes for full DFS. On reaching the end of its subtree a
sweep *holds* the boundary node (the next sibling/ancestor) instead of consuming
it, so the enclosing sweep still sees it — correct regardless of whether the
source has inter-element whitespace (a minified document has no buffering text
nodes, which an earlier consume-on-break version skipped over).
"""
function for_each_child(f, c::Cursor)
    initial = c.depth
    target  = initial + 1
    while next!(c) !== nothing
        if c.depth <= initial
            c.held = true                       # hold the boundary node for the enclosing sweep
            break
        end
        c.depth == target && f(c)
    end
    return c
end

"""
    @for_each_child c child body

Macro form of [`for_each_child`](@ref): run `body` for each immediate child of the
cursor `c`'s current node, binding `child` to `c` (the cursor itself) on each. The
body is **inlined** (not a closure), so it can assign enclosing locals without the
capture-boxing a `do` block incurs — which matters in hot extraction loops where
the body accumulates fields. Same depth/peek semantics as the function form (holds
the boundary node on exit, so it composes when nested). Mirrors the shape of a
node-based `@for_each_immediate_child`.
"""
macro for_each_child(c, child, body)
    quote
        local _cur = $(esc(c))
        local _initial = _cur.depth
        local _target = _initial + 1
        while next!(_cur) !== nothing
            if _cur.depth <= _initial
                _cur.held = true
                break
            end
            if _cur.depth == _target
                local $(esc(child)) = _cur
                $(esc(body))
            end
        end
        _cur
    end
end

"""
    skip_element!(c::Cursor)

With `c` positioned on an `Element`, advance past that element's entire subtree in one
byte-level scan (no internal tokens emitted), so the next [`next!`](@ref) yields the
element's following sibling (or the parent boundary). For structural walks (e.g. layer
discovery) that classify a node but don't need its contents — far cheaper than letting
`for_each_child`/`next!` tokenize the skipped subtree. No-op on non-`Element` nodes.
"""
function skip_element!(c::Cursor)
    c.nodetype === Element || return c
    data = _data(c)
    after = _CURSOR_XT._skip_element_raw(data, c.token.offset + 1)
    if after > ncodeunits(data)
        c.done = true
        c.held = false
        return c
    end
    # Jump the tokenizer to just past the matching close, in M_DEFAULT. Drop enclosing
    # by one to mirror having read this element's CLOSE_TAG / SELF_CLOSE.
    c.st.state = _CURSOR_XT.TokenizerState(after, _CURSOR_XT.M_DEFAULT, _CURSOR_XT.no_token(data))
    c.enclosing -= 1
    c.held = false
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
