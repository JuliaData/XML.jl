#-----------------------------------------------------------------------------# FlatNode — read-only columnar full-DOM reader
# The whole document is materialized ONCE into a FlatStore: one contiguous Vector of isbits
# records with integer index links (parent / first_child / next_sibling) plus a side Vector
# for attributes — instead of Node's per-node heap objects. Zero-copy: records hold byte
# ranges into the retained source; text/attribute values are entity-decoded at access.
# A FlatNode is a lightweight handle (store, index); the Document node is index 1.

struct _FlatAttr                      # isbits, 16 B
    name_offset::Int32; name_len::Int32
    value_offset::Int32; value_len::Int32   # value_len < 0 ⇒ value carries entities (decode at access)
end

struct _FlatRec                       # isbits, no pointers
    kind::NodeType
    parent::Int32
    first_child::Int32
    next_sibling::Int32
    name_offset::Int32; name_len::Int32     # Element tag / PI target
    value_offset::Int32; value_len::Int32   # content; offset == -1 ⇒ NO value (vs empty ""); len < 0 ⇒ entities
    attr_first::Int32; attr_count::Int32
end

struct FlatStore
    source::String
    recs::Vector{_FlatRec}            # recs[1] = the Document node
    attrs::Vector{_FlatAttr}
    spans::Vector{NTuple{2,Int32}}    # per-record source span (start, end) — 0-based, half-open
end

"""
    FlatNode

Read-only handle into a [`FlatStore`](@ref) — XML.jl's fourth reader, alongside `Node`
(mutable DOM), `LazyNode` (pay-per-traversal) and `Cursor` (pull streaming): *`Node`'s read
half at `Cursor`'s GC cost*.

!!! warning "Experimental"
    `FlatNode` is new and marked experimental while its usage settles in the dependent
    ecosystem: API details may still change in a 0.4.x release. Feedback welcome in #82.

    doc = parse(xml, FlatNode)          # or read(filename, FlatNode)
    root = only(eachelement(doc))
    for el in eachelement(root)
        tag(el), attributes(el), value(el)
    end

The whole document is parsed once into a contiguous columnar store (a `Vector` of isbits
records indexing into the retained source string), so building is fast, random access is
O(1), repeated traversals never re-decode structure, and the garbage collector sees a
handful of arrays instead of one object per node. Text and attribute values are zero-copy
`SubString`s, entity-decoded on access.

Compared with `Node`:
- **read-only** — no `push!`/`setindex!`; build documents with `Node` / [`h`](@ref).
- `parent(node)` and `depth(node)` work directly (O(1) / O(depth)) — the store keeps
  parent links, which `Node` does not.
- `==`/`isequal`/`hash` are **structural** (equal decoded content), like every reader —
  cross-reader comparisons included. Positional identity — same node of the same store —
  is [`issamenode`](@ref).
- retention is all-or-nothing: any live handle keeps the whole store (and source) alive.
- documents are limited to 2 GiB / `typemax(Int32)` nodes; parse with `Node` beyond that.

`Node(flatnode)` materializes a handle (and its subtree) as an ordinary mutable `Node`;
`XML.write` accepts a `FlatNode` directly.
"""
struct FlatNode
    store::FlatStore
    i::Int32
end

@inline _rec(n::FlatNode) = @inbounds n.store.recs[n.i]
@inline _fsub(store::FlatStore, off::Int32, len::Int32) =
    @inbounds SubString(store.source, off + 1, prevind(store.source, off + len + 1))

# byte range of a SubString into its (root) parent string
@inline _frng(s::SubString{String}) = (Int32(s.offset), Int32(s.ncodeunits))

# record-update helpers (immutable records; rebuild in place)
@inline _fset_first_child(n::_FlatRec, i::Int32) =
    _FlatRec(n.kind, n.parent, i, n.next_sibling, n.name_offset, n.name_len, n.value_offset, n.value_len, n.attr_first, n.attr_count)
@inline _fset_next_sibling(n::_FlatRec, i::Int32) =
    _FlatRec(n.kind, n.parent, n.first_child, i, n.name_offset, n.name_len, n.value_offset, n.value_len, n.attr_first, n.attr_count)
@inline _fset_value(n::_FlatRec, off::Int32, len::Int32) =
    _FlatRec(n.kind, n.parent, n.first_child, n.next_sibling, n.name_offset, n.name_len, off, len, n.attr_first, n.attr_count)
@inline _fadd_attr(n::_FlatRec, first::Int32) =
    _FlatRec(n.kind, n.parent, n.first_child, n.next_sibling, n.name_offset, n.name_len, n.value_offset, n.value_len,
             n.attr_first == 0 ? first : n.attr_first, n.attr_count + Int32(1))

# wire record `idx` as the next child of the current open parent; returns the parent index
@inline function _fattach!(recs::Vector{_FlatRec}, pstack::Vector{Int32}, lastchild::Vector{Int32}, idx::Int32)
    p = @inbounds pstack[end]
    lc = @inbounds lastchild[end]
    if lc == 0
        @inbounds recs[p] = _fset_first_child(recs[p], idx)
    else
        @inbounds recs[lc] = _fset_next_sibling(recs[lc], idx)
    end
    @inbounds lastchild[end] = idx
    p
end

# Token-stream → FlatStore builder: the same single visibly-pushdown pass as `_parse`
# (see parse.jl), with the same well-formedness checks at the same token points — gated by
# `Val{W}` so :lenient pays nothing — but appending isbits records instead of heap nodes.
function _flat_parse(xml::String, ::Val{W}) where {W}
    ncodeunits(xml) <= typemax(Int32) ||
        error("FlatNode stores byte offsets as Int32: source is larger than 2 GiB. Use `parse(xml, Node)`.")
    recs = _FlatRec[]
    attrs = _FlatAttr[]
    spans = NTuple{2,Int32}[]
    sizehint!(recs, ncodeunits(xml) >> 4)
    sizehint!(spans, ncodeunits(xml) >> 4)
    push!(recs, _FlatRec(Document, Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(-1), Int32(0), Int32(0), Int32(0)))
    push!(spans, (Int32(0), Int32(ncodeunits(xml))))
    pstack    = Int32[1]
    lastchild = Int32[0]
    K = TokenKinds

    cur = Int32(0)                    # record receiving ATTR_* (open element or XML declaration)
    pend = Int32(0)                   # record awaiting its content / span end — patched in place
    pan_off = Int32(0); pan_len = Int32(0)   # pending attribute name
    open_off = Int32(0)               # offset of the last COMMENT/CDATA/DOCTYPE opening marker
    tok_end(t) = Int32(t.offset + t.ncodeunits)

    for token in tokenize(xml)
        k = token.kind
        if k === K.TEXT
            rawtext = raw(token, xml)
            W === :strict && _check_chars_strict(rawtext)
            W === :strict && token.has_entities && _check_charrefs_strict(rawtext)
            off, len = _frng(rawtext)
            token.has_entities && (len = -len)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Text, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (off, off + abs(len)))

        elseif k === K.OPEN_TAG
            nm = tag_name(token, xml)
            W !== :lenient && (isempty(nm) || !_is_name_start(first(nm))) &&
                error("not well-formed: invalid element name \"$nm\"")
            noff, nlen = _frng(nm)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Element, p, Int32(0), Int32(0), noff, nlen, Int32(-1), Int32(0), Int32(0), Int32(0)))
            push!(spans, (Int32(token.offset), Int32(0)))
            push!(pstack, idx); push!(lastchild, Int32(0))
            cur = idx

        elseif k === K.SELF_CLOSE
            ci = @inbounds pstack[end]
            @inbounds spans[ci] = (spans[ci][1], tok_end(token))
            pop!(pstack); pop!(lastchild)

        elseif k === K.CLOSE_TAG
            close_name = tag_name(token, xml)
            length(pstack) > 1 || error("Closing tag </$close_name> with no matching open tag.")
            ci = @inbounds pstack[end]
            open_rec = @inbounds recs[ci]
            t = _fsub_or_empty(xml, open_rec.name_offset, open_rec.name_len)
            t == close_name || error("Mismatched tags: expected </$t>, got </$close_name>.")
            # the CLOSE_TAG token covers `</name`; the closing `>` (ETag: '</' Name S? '>')
            # is consumed silently by the tokenizer — locate it to end the element span
            gt = findnext(==('>'), xml, Int(tok_end(token)) + 1)
            @inbounds spans[ci] = (spans[ci][1], gt === nothing ? tok_end(token) : Int32(gt))
            pop!(pstack); pop!(lastchild)

        elseif k === K.ATTR_NAME
            pan_off, pan_len = _frng(raw(token, xml))

        elseif k === K.ATTR_VALUE
            rawval = attr_value(token, xml)
            W !== :lenient && occursin('<', rawval) && error("not well-formed: '<' in attribute value (XML 1.0 §3.1)")
            W === :strict && _check_chars_strict(rawval)
            W === :strict && token.has_entities && _check_charrefs_strict(rawval)
            name = _fsub_or_empty(xml, pan_off, pan_len)
            r = @inbounds recs[cur]
            ai = r.attr_first
            for _ in 1:r.attr_count
                a = @inbounds attrs[ai]
                _fsub_or_empty(xml, a.name_offset, a.name_len) == name && error("Duplicate attribute: $name")
                ai += Int32(1)
            end
            voff, vlen = _frng(rawval)
            token.has_entities && (vlen = -vlen)
            push!(attrs, _FlatAttr(pan_off, pan_len, voff, vlen))
            @inbounds recs[cur] = _fadd_attr(recs[cur], Int32(length(attrs)))

        elseif k === K.XML_DECL_OPEN
            W !== :lenient && length(pstack) > 1 &&
                error("not well-formed: XML declaration inside element content")
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Declaration, p, Int32(0), Int32(0), Int32(0), Int32(0), Int32(-1), Int32(0), Int32(0), Int32(0)))
            push!(spans, (Int32(token.offset), Int32(0)))
            cur = idx
            pend = idx

        elseif k === K.XML_DECL_CLOSE
            @inbounds spans[pend] = (spans[pend][1], tok_end(token))

        elseif k === K.COMMENT_OPEN || k === K.CDATA_OPEN || k === K.DOCTYPE_OPEN
            open_off = Int32(token.offset)

        elseif k === K.COMMENT_CLOSE || k === K.CDATA_CLOSE || k === K.DOCTYPE_CLOSE || k === K.PI_CLOSE
            @inbounds spans[pend] = (spans[pend][1], tok_end(token))

        elseif k === K.COMMENT_CONTENT
            cmt = raw(token, xml)
            W === :strict && _check_chars_strict(cmt)
            W === :strict && occursin("--", cmt) && error("not well-formed: \"--\" within a comment")
            W === :strict && endswith(cmt, '-') && error("not well-formed: \"-\" immediately before \"-->\" in a comment (XML 1.0 §2.5)")
            off, len = _frng(cmt)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Comment, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.CDATA_CONTENT
            cdata = raw(token, xml)
            W === :strict && _check_chars_strict(cdata)
            off, len = _frng(cdata)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(CData, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.DOCTYPE_CONTENT
            W !== :lenient && length(pstack) > 1 &&
                error("not well-formed: DOCTYPE declaration inside element content")
            off, len = _frng(lstrip(raw(token, xml)))        # mirror _parse: lstrip'd DTD value
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(DTD, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.PI_OPEN
            target = pi_target(token, xml)
            W === :strict && (isempty(target) || !_is_name_start(first(target))) &&
                error("not well-formed: invalid processing-instruction target \"$target\"")
            noff, nlen = _frng(target)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(ProcessingInstruction, p, Int32(0), Int32(0), noff, nlen, Int32(-1), Int32(0), Int32(0), Int32(0)))
            push!(spans, (Int32(token.offset), Int32(0)))
            pend = idx

        elseif k === K.PI_CONTENT
            content = lstrip(raw(token, xml))                # mirror _parse: lstrip'd, empty → none
            W === :strict && _check_chars_strict(content)
            if !isempty(content)
                off, len = _frng(content)
                @inbounds recs[pend] = _fset_value(recs[pend], off, len)
            end
        end
        # TAG_CLOSE: no tree action (element spans close at CLOSE_TAG/SELF_CLOSE)
    end

    if length(pstack) > 1
        open_names = [_fsub_or_empty(xml, recs[i].name_offset, recs[i].name_len) for i in pstack[2:end]]
        error("Unclosed tags: $(join(open_names, ", "))")
    end
    store = FlatStore(xml, recs, attrs, spans)
    W !== :lenient && _check_document_wellformed(children(FlatNode(store, Int32(1))))
    FlatNode(store, Int32(1))
end

@inline _fsub_or_empty(source::String, off::Int32, len::Int32) =
    len > 0 ? (@inbounds SubString(source, off + 1, prevind(source, off + len + 1))) : SubString(source, 1, 0)

#-----------------------------------------------------------------------------# parse / read entry points
Base.parse(xml::AbstractString, ::Type{FlatNode}; wellformed::Symbol=:structural) =
    _flat_parse(_drop_bom(String(xml)), Val(wellformed))
Base.parse(::Type{FlatNode}, xml::AbstractString; wellformed::Symbol=:structural) =
    parse(xml, FlatNode; wellformed)
Base.read(filename::AbstractString, ::Type{FlatNode}; wellformed::Symbol=:structural) =
    parse(String(_normalize_bom(read(filename))), FlatNode; wellformed)
Base.read(io::IO, ::Type{FlatNode}; wellformed::Symbol=:structural) =
    parse(String(_normalize_bom(read(io))), FlatNode; wellformed)

#-----------------------------------------------------------------------------# accessors
@inline nodetype(n::FlatNode) = _rec(n).kind

@inline function tag(n::FlatNode)
    r = _rec(n)
    r.name_len > 0 ? _fsub(n.store, r.name_offset, r.name_len) : nothing
end

@inline function value(n::FlatNode)
    r = _rec(n)
    r.value_offset < 0 && return nothing          # absent (empty content is offset ≥ 0, len 0)
    raw = _fsub(n.store, r.value_offset, abs(r.value_len))
    r.value_len < 0 ? unescape(raw) : raw
end

function attributes(n::FlatNode)
    r = _rec(n)
    r.attr_count == 0 && return nothing
    out = Pair{SubString{String}, SubString{String}}[]
    sizehint!(out, r.attr_count)
    ai = r.attr_first
    for _ in 1:r.attr_count
        a = @inbounds n.store.attrs[ai]
        name = _fsub(n.store, a.name_offset, a.name_len)
        rawv = _fsub(n.store, a.value_offset, abs(a.value_len))
        val = a.value_len < 0 ? _as_substring(unescape(rawv)) : rawv
        push!(out, name => val)
        ai += Int32(1)
    end
    out
end

"""
    sourcetext(n::FlatNode) -> SubString

The node's exact raw source slice, markup included — `<tag …>…</tag>` for an element,
`<!--…-->` for a comment, and the whole document for the Document node. Zero-copy: the
store keeps per-record source spans.
"""
function sourcetext(n::FlatNode)
    so, se = @inbounds n.store.spans[n.i]
    _fsub(n.store, so, se - so)
end

"""
    parent(n::FlatNode) -> FlatNode or nothing

O(1) parent lookup (the flat store keeps parent links). Returns `nothing` for the
Document node.
"""
function Base.parent(n::FlatNode)
    p = _rec(n).parent
    p == 0 ? nothing : FlatNode(n.store, p)
end

"""
    depth(n::FlatNode) -> Int

Depth of the node in its document: the Document node is 1, the root element 2, …
O(depth), via the stored parent links.
"""
function depth(n::FlatNode)
    d = 1
    p = _rec(n).parent
    while p != 0
        d += 1
        p = @inbounds n.store.recs[p].parent
    end
    d
end

#-----------------------------------------------------------------------------# child iteration
struct FlatChildIterator
    store::FlatStore
    first::Int32
end

Base.IteratorSize(::Type{FlatChildIterator}) = Base.SizeUnknown()
Base.eltype(::Type{FlatChildIterator}) = FlatNode

function Base.iterate(it::FlatChildIterator, i::Int32 = it.first)
    i == 0 && return nothing
    (FlatNode(it.store, i), (@inbounds it.store.recs[i].next_sibling))
end

"""
    eachchildnode(n::FlatNode)

Lazy iterator over the children of `n`, one `FlatNode` handle at a time (no vector
materialized). See also [`children`](@ref) and [`eachelement`](@ref).
"""
eachchildnode(n::FlatNode) = FlatChildIterator(n.store, _rec(n).first_child)

function children(n::FlatNode)
    nt = _rec(n).kind
    (nt === Document || nt === Element) || return ()
    out = FlatNode[]
    for c in eachchildnode(n)
        push!(out, c)
    end
    out
end

# eachelement's generic definition filters children(node); build on the lazy child
# iterator instead so no intermediate Vector is materialized (same move as LazyNode's).
eachelement(node::FlatNode) = Iterators.filter(n -> nodetype(n) === Element, eachchildnode(node))

function Base.length(n::FlatNode)
    len = 0
    for _ in eachchildnode(n)
        len += 1
    end
    len
end

function Base.getindex(n::FlatNode, i::Integer)
    k = 0
    for c in eachchildnode(n)
        (k += 1) == i && return c
    end
    throw(BoundsError(n, i))
end

is_simple(n::FlatNode) = (r = _rec(n);
    r.kind === Element && r.attr_count == 0 && r.first_child != 0 &&
    (c = @inbounds n.store.recs[r.first_child]; c.next_sibling == 0 && (c.kind === Text || c.kind === CData)))

is_simple_value(n::FlatNode) = is_simple(n) ? value(FlatNode(n.store, _rec(n).first_child)) : nothing

function simple_value(n::FlatNode)
    is_simple(n) || error("`simple_value` requires a simple node: an Element with no attributes and exactly one Text or CData child. See `is_simple`.")
    value(FlatNode(n.store, _rec(n).first_child))
end

#-----------------------------------------------------------------------------# conversion / write / show
"""
    Node(n::FlatNode) -> Node{String}

Materialize a flat handle (and its whole subtree) as an ordinary mutable `Node`, with
decoded text and attribute values — the bridge from the read-only store to the mutable
DOM (e.g. to edit a subtree or compare content with `==`).
"""
function Node(n::FlatNode)
    r = _rec(n)
    a = attributes(n)
    attrs = a === nothing ? nothing : Pair{String,String}[String(k) => String(v) for (k, v) in a]
    t = tag(n)
    v = value(n)
    ch = (r.kind === Document || r.kind === Element) ?
        Node{String}[Node(c) for c in eachchildnode(n)] : nothing
    Node{String}(r.kind, t === nothing ? nothing : String(t), attrs,
                 v === nothing ? nothing : String(v),
                 ch === nothing || isempty(ch) ? nothing : ch)
end

write(n::FlatNode; kw...) = write(Node(n); kw...)
write(io::IO, n::FlatNode; kw...) = write(io, Node(n); kw...)
write(filename::AbstractString, n::FlatNode; kw...) = write(filename, Node(n); kw...)

function Base.show(io::IO, n::FlatNode)
    r = _rec(n)
    print(io, "FlatNode ", r.kind)
    if r.kind === Element
        print(io, " <", tag(n))
        a = attributes(n)
        if a !== nothing
            for (k, v) in a
                print(io, ' ', k, "=\"", v, '"')
            end
        end
        print(io, '>')
    elseif r.kind === ProcessingInstruction
        print(io, " <?", tag(n), "?>")
    elseif r.value_offset >= 0
        s = something(value(n), "")
        print(io, ' ', repr(first(s, 40)), ncodeunits(s) > 40 ? "…" : "")
    end
    nc = r.kind === Document || r.kind === Element ? length(n) : 0
    nc > 0 && print(io, " (", nc, " children)")
end
