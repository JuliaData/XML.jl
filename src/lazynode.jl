#-----------------------------------------------------------------------------# LazyNode
"""
    LazyNode

A lightweight, read-only view into an XML document that navigates the token stream on demand
instead of building a full tree in memory.

    doc = parse(xml_string, LazyNode)
    doc = read("file.xml", LazyNode)

Supports the same read-only interface as `Node`: [`nodetype`](@ref), [`tag`](@ref),
[`attributes`](@ref), [`value`](@ref), [`children`](@ref), plus integer and string indexing.

Accessor methods (`tag`, `value`, `keys`, `attributes`) return `SubString{String}` views
into the original document rather than allocated `String`s, so reading a large document
through `LazyNode` does not duplicate its text data.
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
# Source string backing a lazy tokenizer (StatefulTokenizer) — needed to reconstruct token
# text now that `Token` holds only a byte range. Used where the owning `LazyNode` is out of
# scope (e.g. inside `LazyAttrIterator`, which carries only the tokenizer).
@inline _src(iter) = iter.t.data

# Entity-decode a TEXT/ATTR_VALUE token only when the tokenizer actually saw a `&`. When
# `has_entities` is false the raw `SubString{String}` view is returned with no allocation
# and no byte scan — the dominant case for spreadsheet-style data. `_decode_attr` strips
# the surrounding quotes first; the flag is read from the token, not the stripped view.
@inline _decode(tok::Token, data) = tok.has_entities ? unescape(raw(tok, data)) : raw(tok, data)
@inline _decode_attr(tok::Token, data) = tok.has_entities ? unescape(attr_value(tok, data)) : attr_value(tok, data)

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

function value(n::LazyNode)
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
        content = strip(raw(result[1], n.data))
        return isempty(content) ? nothing : content
    end
    nothing
end

#-----------------------------------------------------------------------------# attributes
# Promote a `String` returned from `unescape` to a SubString so the homogeneous
# `Attributes{SubString{String}}` parameterization works. The String was already
# allocated for entity decoding; the SubString wrapper is just a view on top.
@inline _as_substring(s::SubString{String}) = s
@inline _as_substring(s::String) = SubString(s, 1, lastindex(s))

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
        push!(attrs, name => _as_substring(_decode_attr(result[1], n.data)))
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
function Base.get(n::LazyNode, key::AbstractString, default)
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
struct LazyAttrIterator{I}
    iter::I
    done::Base.RefValue{Bool}
end

Base.IteratorSize(::Type{<:LazyAttrIterator}) = Base.SizeUnknown()
Base.eltype(::Type{<:LazyAttrIterator}) = Pair{SubString{String}, Union{SubString{String}, String}}

"""
    eachattribute(n::LazyNode)

Lazy iterator yielding `name => value` pairs for the attributes of `n` (an `Element` or
`Declaration`). Does not allocate an [`Attributes`](@ref) dict or intermediate vector;
suitable for hot paths that only need to scan attributes.

For a single attribute by name, prefer `get(n, key, default)` — it short-circuits as soon
as the match is found.
"""
function eachattribute(n::LazyNode)
    iter = _lazy_tokenizer(n)
    is_attrs = n.nodetype === Element || n.nodetype === Declaration
    is_attrs && iterate(iter)  # skip OPEN_TAG / XML_DECL_OPEN
    LazyAttrIterator{typeof(iter)}(iter, Ref(!is_attrs))
end

function Base.iterate(it::LazyAttrIterator, _ = nothing)
    it.done[] && return nothing
    r = iterate(it.iter)
    isnothing(r) && (it.done[] = true; return nothing)
    tok = r[1]
    if tok.kind !== TokenKinds.ATTR_NAME
        it.done[] = true
        return nothing
    end
    name = raw(tok, _src(it.iter))
    r = iterate(it.iter)
    if isnothing(r)
        it.done[] = true
        return nothing
    end
    val = _decode_attr(r[1], _src(it.iter))
    ((name => val), nothing)
end

function Base.getindex(n::LazyNode, key::AbstractString)
    val = get(n, key, _MISSING_ATTR)
    val === _MISSING_ATTR && throw(KeyError(key))
    val
end

function Base.haskey(n::LazyNode, key::AbstractString)
    get(n, key, _MISSING_ATTR) !== _MISSING_ATTR
end

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
struct LazyChildIterator{S <: AbstractString, I}
    data::S
    iter::I
    done::Base.RefValue{Bool}
end

Base.IteratorSize(::Type{<:LazyChildIterator}) = Base.SizeUnknown()
Base.eltype(::Type{LazyChildIterator{S,I}}) where {S,I} = LazyNode{S}

"""
    eachchildnode(n::LazyNode)

Return a lazy iterator over the children of `n`, yielding one [`LazyNode`](@ref) at a time
without collecting them all into a vector.

See also [`children`](@ref), which returns a `Vector{LazyNode}`.
"""
function eachchildnode(n::LazyNode{S}) where {S}
    nt = n.nodetype
    iter = _lazy_tokenizer(n)
    if nt === Document
        return LazyChildIterator{S, typeof(iter)}(n.data, iter, Ref(false))
    elseif nt === Element
        for tok in iter
            if tok.kind === TokenKinds.SELF_CLOSE
                return LazyChildIterator{S, typeof(iter)}(n.data, iter, Ref(true))
            elseif tok.kind === TokenKinds.TAG_CLOSE
                return LazyChildIterator{S, typeof(iter)}(n.data, iter, Ref(false))
            end
        end
    end
    LazyChildIterator{S, typeof(iter)}(n.data, iter, Ref(true))
end

function Base.iterate(ci::LazyChildIterator, _ = nothing)
    ci.done[] && return nothing
    for tok in ci.iter
        k = tok.kind
        if k === TokenKinds.TEXT
            return (LazyNode(ci.data, tok, Text), nothing)
        elseif k === TokenKinds.OPEN_TAG
            node = LazyNode(ci.data, tok, Element)
            _lazy_skip_element!(ci.iter)
            return (node, nothing)
        elseif k === TokenKinds.COMMENT_OPEN
            node = LazyNode(ci.data, tok, Comment)
            _lazy_skip_until!(ci.iter, TokenKinds.COMMENT_CLOSE)
            return (node, nothing)
        elseif k === TokenKinds.CDATA_OPEN
            node = LazyNode(ci.data, tok, CData)
            _lazy_skip_until!(ci.iter, TokenKinds.CDATA_CLOSE)
            return (node, nothing)
        elseif k === TokenKinds.PI_OPEN
            node = LazyNode(ci.data, tok, ProcessingInstruction)
            _lazy_skip_until!(ci.iter, TokenKinds.PI_CLOSE)
            return (node, nothing)
        elseif k === TokenKinds.XML_DECL_OPEN
            node = LazyNode(ci.data, tok, Declaration)
            _lazy_skip_until!(ci.iter, TokenKinds.XML_DECL_CLOSE)
            return (node, nothing)
        elseif k === TokenKinds.DOCTYPE_OPEN
            node = LazyNode(ci.data, tok, DTD)
            _lazy_skip_until!(ci.iter, TokenKinds.DOCTYPE_CLOSE)
            return (node, nothing)
        elseif k === TokenKinds.CLOSE_TAG || k === TokenKinds.TAG_CLOSE
            ci.done[] = true
            return nothing
        end
    end
    ci.done[] = true
    return nothing
end

#-----------------------------------------------------------------------------# is_simple / simple_value
function is_simple(n::LazyNode)
    n.nodetype === Element || return false
    attrs = attributes(n)
    (!isnothing(attrs) && !isempty(attrs)) && return false
    ch = children(n)
    length(ch) == 1 && ch[1].nodetype in (Text, CData)
end

function simple_value(n::LazyNode)
    n.nodetype === Element || error("`simple_value` is only defined for simple nodes.")
    attrs = attributes(n)
    (!isnothing(attrs) && !isempty(attrs)) && error("`simple_value` is only defined for simple nodes.")
    ch = children(n)
    length(ch) == 1 && ch[1].nodetype in (Text, CData) || error("`simple_value` is only defined for simple nodes.")
    value(ch[1])
end

# Single-pass combined predicate+accessor: returns the simple text/CData value, or
# `nothing` if `n` is not a simple element. Avoids the double tokenization of
# `is_simple(n) ? simple_value(n) : ...`.
function is_simple_value(n::LazyNode)
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
Base.parse(xml::AbstractString, ::Type{LazyNode}) = LazyNode(String(xml), Document)

Base.read(filename::AbstractString, ::Type{LazyNode}) = parse(read(filename, String), LazyNode)
Base.read(io::IO, ::Type{LazyNode}) = parse(read(io, String), LazyNode)

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
