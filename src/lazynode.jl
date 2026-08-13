#-----------------------------------------------------------------------------# LazyNode
"""
    LazyNode

A lightweight, read-only view into an XML document that navigates the token stream on demand
instead of building a full tree in memory.

    doc = parse(xml_string, LazyNode)
    doc = read("file.xml", LazyNode)

Supports the same read-only interface as `Node`: [`nodetype`](@ref), [`tag`](@ref),
[`attributes`](@ref), [`value`](@ref), [`children`](@ref), plus integer and string indexing.
Accessors return `SubString{String}` views into the original document, so navigating a large
document through `LazyNode` does not duplicate its text data.

# Performance — which reader to use

`LazyNode` holds **no materialized tree**, only the source string, so its resident footprint is
roughly the document size — about an order of magnitude smaller than the equivalent `Node` tree.
The trade-off is that it **re-tokenizes on every access**: one traversal is somewhat slower than
`Node`, and *repeated* traversals are dramatically slower (each pass re-scans the whole document),
whereas a `Node` tree is built once and then walked cheaply.

- **Forward streaming of a large document** → [`Cursor`](@ref) — fastest, allocation-free.
- **Repeated or random access** → [`Node`](@ref) — builds the tree once.
- **`LazyNode`** → low-memory, *read-once* navigation, or as a holdable snapshot of a
  [`Cursor`](@ref) position (`LazyNode(c)` / `Cursor(::LazyNode)`).
"""
struct LazyNode{S <: AbstractString}
    data::S
    token::Token
    nodetype::NodeType
end

function LazyNode(data::S, nt::NodeType) where {S <: AbstractString}
    LazyNode{S}(data, Token(TokenKinds.TEXT, SubString(data, 1, 0)), nt)
end

nodetype(n::LazyNode) = n.nodetype

_lazy_pos(n::LazyNode) = n.token.offset + 1
_lazy_tokenizer(n::LazyNode) = tokenize(n.data, _lazy_pos(n))
# Entity-decode a TEXT/ATTR_VALUE token only when the tokenizer actually saw a `&`. When
# `has_entities` is false the raw `SubString{String}` view is returned with no allocation
# and no byte scan — the dominant case for spreadsheet-style data. `_decode_attr` strips
# the surrounding quotes first; the flag is read from the token, not the stripped view.
@inline _decode(tok::Token, data) = tok.has_entities ? unescape(raw(tok, data)) : raw(tok, data)
@inline function _decode_attr(tok::Token, data)
    v = _normalize_attr_ws(attr_value(tok, data))
    tok.has_entities ? unescape(v) : v
end

#-----------------------------------------------------------------------------# tag / value
function tag(n::LazyNode)
    nt = n.nodetype
    if nt === Element
        return tag_name(n.token, n.data)
    elseif nt === ProcessingInstruction
        return pi_target(n.token, n.data)
    end
    nothing
end

# @inline: the `Union{Nothing, SubString{String}}` return only stays box-free when the
# caller can union-split it — across a non-inlined boundary it costs 32 B per call (#105).
# Same reason on the other union-returning accessors below and in cursor.jl/flatnode.jl.
@inline function value(n::LazyNode)
    nt = n.nodetype
    if nt === Text
        return _decode(n.token, n.data)
    elseif nt === Comment
        iter = _lazy_tokenizer(n)
        iterate(iter)  # COMMENT_OPEN
        return raw(iterate(iter)[1], n.data)
    elseif nt === CData
        iter = _lazy_tokenizer(n)
        iterate(iter)  # CDATA_OPEN
        return raw(iterate(iter)[1], n.data)
    elseif nt === DTD
        iter = _lazy_tokenizer(n)
        iterate(iter)  # DOCTYPE_OPEN
        return lstrip(raw(iterate(iter)[1], n.data))
    elseif nt === ProcessingInstruction
        iter = _lazy_tokenizer(n)
        iterate(iter)  # PI_OPEN
        result = iterate(iter)
        result === nothing && return nothing
        result[1].kind === TokenKinds.PI_CONTENT || return nothing
        content = lstrip(raw(result[1], n.data))
        return isempty(content) ? nothing : content
    end
    nothing
end

#-----------------------------------------------------------------------------# attributes
function attributes(n::LazyNode)
    n.nodetype in (Element, Declaration) || return nothing
    iter = _lazy_tokenizer(n)
    iterate(iter)  # skip OPEN_TAG or XML_DECL_OPEN
    attrs = Pair{SubString{String}, SubString{String}}[]
    for tok in iter
        tok.kind === TokenKinds.ATTR_NAME || break
        name = raw(tok, n.data)
        result = iterate(iter)
        result === nothing && break
        push!(attrs, name => _decode_attr(result[1], n.data))
    end
    isempty(attrs) ? nothing : Attributes(attrs)
end

"""
    get(n::LazyNode, key::AbstractString, default)

Return the value of attribute `key` on `n`, or `default` if absent. Walks the token stream
once — no `Attributes` allocation — so this is the recommended way to read a single
attribute from a `LazyNode`. Use [`eachattribute`](@ref) to stream all attribute pairs
without allocating, or [`attributes`](@ref) for the materialized dict.
"""
@inline function Base.get(n::LazyNode, key::AbstractString, default)
    n.nodetype in (Element, Declaration) || return default
    iter = _lazy_tokenizer(n)
    iterate(iter)  # skip OPEN_TAG or XML_DECL_OPEN
    for tok in iter
        tok.kind === TokenKinds.ATTR_NAME || return default
        if raw(tok, n.data) == key
            result = iterate(iter)
            result === nothing && return default
            return _decode_attr(result[1], n.data)
        else
            iterate(iter)  # skip value
        end
    end
    default
end

#-----------------------------------------------------------------------------# eachattribute
# Same shared-cursor design as `LazyChildIterator`: the isbits tokenizer state lives in
# a mutable field, so every loop over the same object resumes where the last one stopped,
# and an exhausted iterator stays exhausted (`active` latches false).
mutable struct LazyAttrIterator{S <: AbstractString}
    const data::S
    const t::Tokenizer{S}
    state::TokenizerState
    active::Bool
end

Base.IteratorSize(::Type{<:LazyAttrIterator}) = Base.SizeUnknown()
Base.eltype(::Type{<:LazyAttrIterator}) = Pair{SubString{String}, SubString{String}}

"""
    eachattribute(n::LazyNode)

Lazy iterator yielding decoded `name => value` pairs for the attributes of `n` (an
`Element` or `Declaration`). Iteration steps allocate nothing — no [`Attributes`](@ref)
dict, no intermediate vector, no per-pair boxing; creating the iterator costs one small
object — suitable for hot paths that scan every attribute.

The iterator holds one shared cursor: every loop over the same object resumes after the
last yielded pair, and an exhausted iterator stays exhausted — call `eachattribute`
again for a fresh pass.

For a single attribute by name, prefer `get(n, key, default)` — it short-circuits as soon
as the match is found.
"""
@inline function eachattribute(n::LazyNode{S}) where {S}
    t = Tokenizer(n.data, _lazy_pos(n))
    st = _init_state(t)
    is_attrs = n.nodetype === Element || n.nodetype === Declaration
    if is_attrs
        r = iterate(t, st)  # skip OPEN_TAG / XML_DECL_OPEN
        isnothing(r) || (st = r[2])
    end
    LazyAttrIterator{S}(n.data, t, st, is_attrs)
end

@inline function Base.iterate(it::LazyAttrIterator, _ = nothing)
    it.active || return nothing
    r = iterate(it.t, it.state)
    isnothing(r) && (it.active = false; return nothing)
    tok, st = r
    tok.kind === TokenKinds.ATTR_NAME || (it.active = false; return nothing)
    name = raw(tok, it.data)
    r = iterate(it.t, st)
    isnothing(r) && (it.active = false; return nothing)
    vtok, st = r
    it.state = st
    ((name => _decode_attr(vtok, it.data)), nothing)
end

#-----------------------------------------------------------------------------# foreach_attr
"""
    foreach_attr(f, n::LazyNode)

Call `f(name_token, value_token)` for each attribute of `n` (an `Element` or
`Declaration`), where both arguments are raw `Token` values.

To read attributes as decoded `name => value` pairs, use [`eachattribute`](@ref) — it is
equally allocation-light. The token layer only makes sense for consumers that need byte
offsets or the verbatim source: `XML.XMLTokenizer.attr_value(tok, n.data)` strips the
surrounding quotes but performs **no** character-reference resolution and **no** XML 1.0
§3.3.3 white-space normalization, so its output differs from the decoded accessors
whenever an attribute carries references or literal tab/newline/CR.
"""
function foreach_attr(f, n::LazyNode{String})
    n.nodetype in (Element, Declaration) || return
    iter = _lazy_tokenizer(n)
    iterate(iter)  # skip OPEN_TAG / XML_DECL_OPEN
    while true
        r = iterate(iter)
        isnothing(r) && return
        name_tok = r[1]
        name_tok.kind === TokenKinds.ATTR_NAME || return
        r = iterate(iter)
        isnothing(r) && return
        f(name_tok, r[1])
    end
end

@inline function Base.getindex(n::LazyNode, key::AbstractString)
    val = get(n, key, nothing)
    val === nothing && throw(KeyError(key))
    val
end

@inline Base.haskey(n::LazyNode, key::AbstractString) = get(n, key, nothing) !== nothing

function Base.keys(n::LazyNode)
    n.nodetype in (Element, Declaration) || return ()
    iter = _lazy_tokenizer(n)
    iterate(iter)
    result = SubString{String}[]
    for tok in iter
        tok.kind === TokenKinds.ATTR_NAME || break
        push!(result, raw(tok, n.data))
        iterate(iter)  # skip value
    end
    result
end

#-----------------------------------------------------------------------------# children
function children(n::LazyNode{S}) where {S}
    nt = n.nodetype
    (nt === Document || nt === Element) || return ()
    children!(LazyNode{S}[], n)
end

"""
    children!(buf::Vector{LazyNode{S}}, n::LazyNode{S}) -> buf

Collect children of `n` into `buf` (cleared first) and return it. Lets callers reuse a
single buffer across many nodes — useful when streaming through siblings (e.g. XLSX row
iteration) to avoid one `Vector` allocation per node.
"""
function children!(buf::Vector{LazyNode{S}}, n::LazyNode{S}) where {S}
    empty!(buf)
    nt = n.nodetype
    if nt === Document
        return _lazy_collect_children!(buf, n.data, _lazy_tokenizer(n))
    elseif nt !== Element
        return buf
    end
    iter = _lazy_tokenizer(n)
    for tok in iter
        tok.kind === TokenKinds.SELF_CLOSE && return buf
        tok.kind === TokenKinds.TAG_CLOSE && break
    end
    _lazy_collect_children!(buf, n.data, iter)
end

function _lazy_collect_children!(result::Vector{LazyNode{S}}, data::S, iter) where {S <: AbstractString}
    for tok in iter
        k = tok.kind
        if k === TokenKinds.TEXT
            push!(result, LazyNode(data, tok, Text))
        elseif k === TokenKinds.OPEN_TAG
            push!(result, LazyNode(data, tok, Element))
            _lazy_skip_element!(iter)
        elseif k === TokenKinds.COMMENT_OPEN
            push!(result, LazyNode(data, tok, Comment))
            _lazy_skip_until!(iter, TokenKinds.COMMENT_CLOSE)
        elseif k === TokenKinds.CDATA_OPEN
            push!(result, LazyNode(data, tok, CData))
            _lazy_skip_until!(iter, TokenKinds.CDATA_CLOSE)
        elseif k === TokenKinds.PI_OPEN
            push!(result, LazyNode(data, tok, ProcessingInstruction))
            _lazy_skip_until!(iter, TokenKinds.PI_CLOSE)
        elseif k === TokenKinds.XML_DECL_OPEN
            push!(result, LazyNode(data, tok, Declaration))
            _lazy_skip_until!(iter, TokenKinds.XML_DECL_CLOSE)
        elseif k === TokenKinds.DOCTYPE_OPEN
            push!(result, LazyNode(data, tok, DTD))
            _lazy_skip_until!(iter, TokenKinds.DOCTYPE_CLOSE)
        elseif k === TokenKinds.CLOSE_TAG
            break
        end
    end
    result
end

function _lazy_skip_element!(iter)
    depth = 1
    for tok in iter
        k = tok.kind
        if k === TokenKinds.OPEN_TAG
            depth += 1
        elseif k === TokenKinds.SELF_CLOSE
            depth -= 1
            depth == 0 && return
        elseif k === TokenKinds.CLOSE_TAG
            depth -= 1
            if depth == 0
                iterate(iter)  # consume trailing TAG_CLOSE
                return
            end
        end
    end
end

function _lazy_skip_until!(iter, target::TokenKinds.Kind)
    for tok in iter
        tok.kind === target && return
    end
end

# Functional twins of the skip helpers: advance the stateless `Tokenizer` from `st` and
# return the state after the skipped construct. The lazy iterators call these from
# `_ci_next` and store the returned state back into their own mutable cursor fields
# (the shared-cursor resumption contract on `LazyChildIterator`).
function _skip_until(t::Tokenizer, st::TokenizerState, target::TokenKinds.Kind)
    while true
        r = iterate(t, st)
        isnothing(r) && return st
        tok, st = r
        tok.kind === target && return st
    end
end

function _skip_element(t::Tokenizer, st::TokenizerState)
    depth = 1
    while true
        r = iterate(t, st)
        isnothing(r) && return st
        tok, st = r
        k = tok.kind
        if k === TokenKinds.OPEN_TAG
            depth += 1
        elseif k === TokenKinds.SELF_CLOSE
            depth -= 1
            depth == 0 && return st
        elseif k === TokenKinds.CLOSE_TAG
            depth -= 1
            if depth == 0
                r = iterate(t, st)  # consume trailing TAG_CLOSE
                return isnothing(r) ? st : r[2]
            end
        end
    end
end

_token_end(tok) = tok.offset + tok.ncodeunits

function _scan_to_close(iter, close_kind::TokenKinds.Kind)
    for tok in iter
        tok.kind === close_kind && return _token_end(tok)
    end
    error("Could not find closing token")
end

#-----------------------------------------------------------------------------# sourcetext
"""
    sourcetext(n::LazyNode) -> SubString{String}

Return the original source text of the node as a `SubString`, with no parsing, escaping,
or reformatting.  This is the zero-copy counterpart of [`write`](@ref) for lazy nodes.
"""
function sourcetext(n::LazyNode)
    nt = n.nodetype
    start = _lazy_pos(n)
    if nt === Element
        iter = _lazy_tokenizer(n)
        for tok in iter
            tok.kind === TokenKinds.SELF_CLOSE && return SubString(n.data, start, _token_end(tok))
            tok.kind === TokenKinds.TAG_CLOSE && break
        end
        depth = 1
        for tok in iter
            k = tok.kind
            if k === TokenKinds.OPEN_TAG
                depth += 1
            elseif k === TokenKinds.SELF_CLOSE
                depth -= 1
            elseif k === TokenKinds.CLOSE_TAG
                depth -= 1
                if depth == 0
                    result = iterate(iter)
                    result === nothing && error("Could not find closing '>'")
                    return SubString(n.data, start, _token_end(result[1]))
                end
            end
        end
        error("Could not find closing tag")
    elseif nt === Comment
        return SubString(n.data, start, _scan_to_close(_lazy_tokenizer(n), TokenKinds.COMMENT_CLOSE))
    elseif nt === CData
        return SubString(n.data, start, _scan_to_close(_lazy_tokenizer(n), TokenKinds.CDATA_CLOSE))
    elseif nt === ProcessingInstruction
        return SubString(n.data, start, _scan_to_close(_lazy_tokenizer(n), TokenKinds.PI_CLOSE))
    elseif nt === Declaration
        return SubString(n.data, start, _scan_to_close(_lazy_tokenizer(n), TokenKinds.XML_DECL_CLOSE))
    elseif nt === DTD
        return SubString(n.data, start, _scan_to_close(_lazy_tokenizer(n), TokenKinds.DOCTYPE_CLOSE))
    elseif nt === Text
        return raw(n.token, n.data)
    elseif nt === Document
        return SubString(n.data)
    end
end

"""
    sourcespan(n::LazyNode) -> UnitRange{Int}

The range of *valid character indices* of the node's original source text within the
retained source string, so that `source[sourcespan(n)] == sourcetext(n)` — the positional
counterpart of [`sourcetext`](@ref), for consumers that need *where* the node lives rather
than its text (verbatim excision and splicing, error context).

The bounds are character indices, not code units: the library performs the `prevind`
computation, so a node ending on a multi-byte character yields indices that are safe to
slice with. To splice text *around* a node, step over its boundaries with
`prevind`/`nextind`:

    s[1:prevind(s, first(span))] * replacement * s[nextind(s, last(span)):end]

The packaged form of that splice is [`splicetext`](@ref).

Defined for the two source-retaining readers (`LazyNode`, `FlatNode`); like `sourcetext`,
it does not apply to `Node`, which retains no source.
"""
function sourcespan(n::LazyNode)
    ss = sourcetext(n)
    o = ss.offset
    isempty(ss) && return (o + 1):o
    (o + 1):prevind(ss.string, o + ncodeunits(ss) + 1)
end

# the multi-byte-safe splice around a character-index span (shared by the two handle readers)
_splice_span(src::AbstractString, span::UnitRange{Int}, replacement::AbstractString) =
    string(SubString(src, firstindex(src), prevind(src, first(span))), replacement,
           SubString(src, nextind(src, last(span))))

"""
    splicetext(n, replacement::AbstractString = "") -> String

The node's document source with the node's own text replaced by `replacement` — excised
entirely by default. This is the packaged, multi-byte-safe form of splicing around
[`sourcespan`](@ref): `Base.splice!`'s remove-and-insert, applied to the retained source
and returning a new `String` (nothing is mutated).

Defined for the two source-retaining readers (`LazyNode`, `FlatNode`).
"""
splicetext(n::LazyNode, replacement::AbstractString = "") =
    _splice_span(n.data, sourcespan(n), replacement)

#-----------------------------------------------------------------------------# write
"""
    write(n::LazyNode; normalize::Bool=false, indentsize::Int=2) -> String
    write(io::IO, n::LazyNode; normalize::Bool=false, indentsize::Int=2)
    write(filename::AbstractString, n::LazyNode; normalize::Bool=false, indentsize::Int=2)

Serialize a `LazyNode`. With `normalize=false` (the default) the result is the node's
original source bytes (zero-copy via [`sourcetext`](@ref)) — fast, but any source-side
whitespace between tags is preserved verbatim.

With `normalize=true` the node is parsed into a `Node` tree and re-serialized, which
collapses incidental source whitespace and pretty-prints with `indentsize`-space
indentation.
"""
function write(n::LazyNode; normalize::Bool=false, indentsize::Int=2)
    normalize ? write(parse(String(sourcetext(n)), Node); indentsize) : String(sourcetext(n))
end

function write(io::IO, n::LazyNode; normalize::Bool=false, indentsize::Int=2)
    if normalize
        write(io, parse(String(sourcetext(n)), Node); indentsize)
    else
        Base.write(io, sourcetext(n))
    end
end

function write(filename::AbstractString, n::LazyNode; normalize::Bool=false, indentsize::Int=2)
    open(io -> write(io, n; normalize, indentsize), filename, "w")
end

#-----------------------------------------------------------------------------# eachchildnode
# Iterator state: a yielded element's subtree is NOT skipped at yield time — the skip is
# recorded as pending and performed only when the next sibling is requested, so a
# traversal that stops early never pays for subtrees nobody asked to step past.
const _CI_READY   = 0x00
const _CI_PENDING = 0x01  # an element was yielded; its unskipped subtree lies ahead
const _CI_DONE    = 0x02

# One shared cursor per iterator object, held as inline isbits fields (no `Ref`, no
# mutable tokenizer wrapper): every loop over the same object RESUMES where the last one
# stopped — downstream row streams (XLSX.jl) store one child iterator and pull from it
# with a fresh `for … break` per row, so the resumption semantics are load-bearing. When
# the iterator does not escape its loop, escape analysis keeps the object off the heap.
mutable struct LazyChildIterator{S <: AbstractString}
    const data::S
    const t::Tokenizer{S}
    state::TokenizerState
    phase::UInt8  # _CI_READY / _CI_PENDING / _CI_DONE
end

Base.IteratorSize(::Type{<:LazyChildIterator}) = Base.SizeUnknown()
Base.eltype(::Type{LazyChildIterator{S}}) where {S} = LazyNode{S}

"""
    eachchildnode(n::LazyNode)

Return a lazy iterator over the children of `n`, yielding one [`LazyNode`](@ref) at a time
without collecting them all into a vector.

The iterator holds one shared cursor: every loop over the same object resumes after the
last yielded child — the contract downstream row streams rely on — and an exhausted
iterator stays exhausted. Call `eachchildnode` again for a fresh pass;
[`eachelement`](@ref) built on a `LazyNode` inherits the same semantics. Iteration steps
allocate nothing; creating the iterator costs one small object.

See also [`children`](@ref), which returns a `Vector{LazyNode}`.
"""
@inline function eachchildnode(n::LazyNode{S}) where {S}
    nt = n.nodetype
    t = Tokenizer(n.data, _lazy_pos(n))
    st = _init_state(t)
    if nt === Document
        return LazyChildIterator{S}(n.data, t, st, _CI_READY)
    elseif nt === Element
        while true
            r = iterate(t, st)
            isnothing(r) && break
            tok, st = r
            if tok.kind === TokenKinds.SELF_CLOSE
                return LazyChildIterator{S}(n.data, t, st, _CI_DONE)
            elseif tok.kind === TokenKinds.TAG_CLOSE
                return LazyChildIterator{S}(n.data, t, st, _CI_READY)
            end
        end
    end
    LazyChildIterator{S}(n.data, t, st, _CI_DONE)
end

# eachelement's generic definition filters children(node); for LazyNode, build on the
# lazy child iterator instead so no intermediate Vector is materialized. The filter is a
# dedicated iterator rather than Iterators.filter: the child protocol's union return only
# stays unboxed while the whole iterate chain inlines, and Base's Filter breaks the chain.
struct LazyElementIterator{S <: AbstractString}
    ci::LazyChildIterator{S}
end
Base.IteratorSize(::Type{<:LazyElementIterator}) = Base.SizeUnknown()
Base.eltype(::Type{LazyElementIterator{S}}) where {S} = LazyNode{S}

@inline eachelement(node::LazyNode) = LazyElementIterator(eachchildnode(node))

@inline Base.iterate(ei::LazyElementIterator, _ = nothing) = _ei_filter(ei.ci)
@inline function _ei_filter(ci::LazyChildIterator)
    while true
        r = iterate(ci)
        r === nothing && return nothing
        r[1].nodetype === Element && return r
    end
end

# The passed iteration state is ignored — the cursor lives in the iterator's own fields
# (the resumption contract above). The yielded tuple is built at a SINGLE site — an
# unboxed union return survives only one construction path (the same rule the span→view
# helpers pin down) — and the chain must inline into the caller's loop: across a
# non-inlined boundary the union boxes per step.
@inline Base.iterate(ci::LazyChildIterator, _ = nothing) = _ci_next(ci)

@inline function _ci_next(ci::LazyChildIterator)
    phase = ci.phase
    phase === _CI_DONE && return nothing
    t = ci.t
    st = ci.state
    if phase === _CI_PENDING
        st = _skip_element(t, st)
    end
    while true
        r = iterate(t, st)
        if isnothing(r)
            ci.phase = _CI_DONE
            return nothing
        end
        tok, st = r
        k = tok.kind
        newphase = _CI_READY
        local nt::NodeType
        if k === TokenKinds.TEXT
            nt = Text
        elseif k === TokenKinds.OPEN_TAG
            nt = Element
            newphase = _CI_PENDING
        elseif k === TokenKinds.COMMENT_OPEN
            nt = Comment
            st = _skip_until(t, st, TokenKinds.COMMENT_CLOSE)
        elseif k === TokenKinds.CDATA_OPEN
            nt = CData
            st = _skip_until(t, st, TokenKinds.CDATA_CLOSE)
        elseif k === TokenKinds.PI_OPEN
            nt = ProcessingInstruction
            st = _skip_until(t, st, TokenKinds.PI_CLOSE)
        elseif k === TokenKinds.XML_DECL_OPEN
            nt = Declaration
            st = _skip_until(t, st, TokenKinds.XML_DECL_CLOSE)
        elseif k === TokenKinds.DOCTYPE_OPEN
            nt = DTD
            st = _skip_until(t, st, TokenKinds.DOCTYPE_CLOSE)
        elseif k === TokenKinds.CLOSE_TAG || k === TokenKinds.TAG_CLOSE
            ci.phase = _CI_DONE
            return nothing
        else
            continue
        end
        ci.state = st
        ci.phase = newphase
        return (LazyNode(ci.data, tok, nt), nothing)
    end
end

#-----------------------------------------------------------------------------# is_simple / simple_value
function is_simple(n::LazyNode)
    n.nodetype === Element || return false
    attrs = attributes(n)
    (!isnothing(attrs) && !isempty(attrs)) && return false
    ch = children(n)
    length(ch) == 1 && ch[1].nodetype in (Text, CData)
end

# Delegates to the single-pass token walk of `is_simple_value` — materializing
# `attributes` + `children` just to validate simplicity costs ~10× the walk (#105).
@inline function simple_value(n::LazyNode)
    v = is_simple_value(n)
    v === nothing && error("`simple_value` is only defined for simple nodes.")
    v
end

# Single-pass combined predicate+accessor: returns the simple text/CData value, or
# `nothing` if `n` is not a simple element. Avoids the double tokenization of
# `is_simple(n) ? simple_value(n) : ...`.
@inline function is_simple_value(n::LazyNode)
    n.nodetype === Element || return nothing
    iter = _lazy_tokenizer(n)
    iterate(iter)  # skip OPEN_TAG
    found_close = false
    for tok in iter
        k = tok.kind
        k === TokenKinds.TAG_CLOSE && (found_close = true; break)
        return nothing  # attributes (ATTR_NAME), self-close, or anything else => not simple
    end
    found_close || return nothing
    result = iterate(iter)
    isnothing(result) && return nothing
    tok = result[1]
    k = tok.kind
    if k === TokenKinds.TEXT
        nxt = iterate(iter)
        (isnothing(nxt) || nxt[1].kind !== TokenKinds.CLOSE_TAG) && return nothing
        return _decode(tok, n.data)
    elseif k === TokenKinds.CDATA_OPEN
        r = iterate(iter)
        (isnothing(r) || r[1].kind !== TokenKinds.CDATA_CONTENT) && return nothing
        content = raw(r[1], n.data)
        r = iterate(iter)
        (isnothing(r) || r[1].kind !== TokenKinds.CDATA_CLOSE) && return nothing
        r = iterate(iter)
        (isnothing(r) || r[1].kind !== TokenKinds.CLOSE_TAG) && return nothing
        return content
    end
    nothing
end

#-----------------------------------------------------------------------------# indexing
Base.getindex(n::LazyNode, i::Integer) = children(n)[i]
Base.getindex(n::LazyNode, ::Colon) = children(n)
Base.lastindex(n::LazyNode) = lastindex(children(n))
Base.only(n::LazyNode) = only(children(n))
Base.length(n::LazyNode) = length(children(n))

#-----------------------------------------------------------------------------# parse / read
Base.parse(::Type{LazyNode}, xml::AbstractString) = parse(xml, LazyNode)
Base.parse(xml::AbstractString, ::Type{LazyNode}) = LazyNode(_drop_bom(String(xml)), Document)

Base.read(filename::AbstractString, ::Type{LazyNode}) = parse(String(_normalize_bom(read(filename))), LazyNode)
Base.read(io::IO, ::Type{LazyNode}) = parse(String(_normalize_bom(read(io))), LazyNode)

#-----------------------------------------------------------------------------# show
function Base.show(io::IO, n::LazyNode)
    nt = n.nodetype
    print(io, "Lazy ", nt)
    if nt === Text
        print(io, ' ', repr(value(n)))
    elseif nt === Element
        print(io, " <", tag(n))
        attrs = attributes(n)
        if !isnothing(attrs)
            for (k, v) in attrs
                print(io, ' ', k, '=', '"', v, '"')
            end
        end
        print(io, '>')
    elseif nt === DTD
        print(io, " <!DOCTYPE ", value(n), '>')
    elseif nt === Declaration
        print(io, " <?xml")
        attrs = attributes(n)
        if !isnothing(attrs)
            for (k, v) in attrs
                print(io, ' ', k, '=', '"', v, '"')
            end
        end
        print(io, "?>")
    elseif nt === ProcessingInstruction
        print(io, " <?", tag(n))
        v = value(n)
        !isnothing(v) && print(io, ' ', v)
        print(io, "?>")
    elseif nt === Comment
        print(io, " <!--", value(n), "-->")
    elseif nt === CData
        print(io, " <![CDATA[", value(n), "]]>")
    elseif nt === Document
        n_ch = length(children(n))
        n_ch > 0 && print(io, n_ch == 1 ? " (1 child)" : " ($n_ch children)")
    end
end
