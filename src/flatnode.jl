#-----------------------------------------------------------------------------# FlatNode — read-only columnar full-DOM reader
# The whole document is materialized ONCE into a FlatStore: one contiguous Vector of isbits
# records with integer index links (parent / first_child / next_sibling) plus a side Vector
# for attributes — instead of Node's per-node heap objects. Zero-copy: records hold byte
# ranges into the retained source, and text/attribute values are normalized and decoded at
# access. A FlatNode is a lightweight handle (store, index); the Document node is index 1.

struct _FlatAttr                      # isbits, 16 B
    name_offset::Int32; name_len::Int32
    value_offset::Int32; value_len::Int32   # value_len < 0 ⇒ value carries entities (decode at access)
end

# A value that needs work before it is returned has a negative `value_len`. A Text says
# which work in its `name_len`, a field it does not use: 0 references to decode, -1 line
# ends to normalize (§2.11), -2 both. Any other kind holds no reference: its work is its
# line ends.
struct _FlatRec                       # isbits, no pointers
    kind::NodeType
    parent::Int32
    first_child::Int32
    next_sibling::Int32
    name_offset::Int32; name_len::Int32     # Element tag / PI target; Text: its work, see above
    value_offset::Int32; value_len::Int32   # content; offset == -1 ⇒ NO value (vs empty ""); len < 0 ⇒ work
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
(mutable DOM), `LazyNode` (decodes on each traversal) and `Cursor` (pull streaming): the
random-access read API of `Node` at almost none of its GC cost.

!!! warning "Experimental"
    `FlatNode` is new and marked experimental while its usage settles in the dependent
    ecosystem: API details may still change in a 0.4.x release. Feedback is welcome on
    the issue tracker.

    doc = parse(xml, FlatNode)          # or read(filename, FlatNode)
    root = only(eachelement(doc))
    for el in eachelement(root)
        tag(el), attributes(el), value(el)
    end

`parse` and `read` take the same `wellformed` keyword as for [`Node`](@ref): `:lenient`,
`:structural` (the default) or `:strict`.

The whole document is parsed once into a contiguous columnar store (a `Vector` of isbits
records indexing into the retained source string), so building is fast, random access is
O(1), repeated traversals never re-decode structure, and the garbage collector sees a
handful of arrays instead of one object per node. Text and attribute values are zero-copy
`SubString`s, entity-decoded on access, and their line ends are normalized as they are read.

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
# Span→view via the tokenizer's fully-elided noshift path: every span the store records
# is a token span or the field pair of a tokenizer accessor's SubString (see `_frng`
# below), so both edges are UTF-8 character boundaries by construction — the same
# invariant as XMLTokenizer's `_noshift_substring`, one hop removed (#113).
# `--check-bounds=yes` still validates every span.
@inline _fsub(store::FlatStore, off::Int32, len::Int32) =
    @inbounds _noshift_substring(store.source, Int(off), Int(len))

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
# `Val{W}` so :lenient costs nothing — but appending isbits records instead of heap nodes.
function _flat_parse(xml::String, lastcr::Int, ::Val{W}) where {W}
    strict = W === :strict ? _strict_context(xml) : _NO_DTD
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
    large_tag = false                 # record `cur` has more than `_SMALL_ATTRIBUTE_COUNT` attributes
    tok_end(t) = Int32(t.offset + t.ncodeunits)

    for token in tokenize(xml)
        k = token.kind
        if k === K.TEXT
            rawtext = raw(token, xml)
            W === :strict && _check_chars_strict(rawtext)
            W === :strict && token.has_entities && _check_refs_strict(rawtext, strict, false)
            off, len = _frng(rawtext)
            voff, vlen, cr = _flat_value(rawtext, off, len, lastcr)
            (token.has_entities || cr) && (vlen = -vlen)
            work = cr ? (token.has_entities ? Int32(-2) : Int32(-1)) : Int32(0)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Text, p, Int32(0), Int32(0), Int32(0), work, voff, vlen, Int32(0), Int32(0)))
            push!(spans, (off, off + len))

        elseif k === K.OPEN_TAG
            nm = tag_name(token, xml)
            if W === :strict
                _is_xml10_name(nm) || _not_a_name("element name", nm)
            elseif W !== :lenient
                (isempty(nm) || !_is_name_start(first(nm))) &&
                    error("not well-formed: invalid element name \"$nm\"")
            end
            noff, nlen = _frng(nm)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Element, p, Int32(0), Int32(0), noff, nlen, Int32(-1), Int32(0), Int32(0), Int32(0)))
            push!(spans, (Int32(token.offset), Int32(0)))
            push!(pstack, idx); push!(lastchild, Int32(0))
            cur = idx

        elseif k === K.SELF_CLOSE
            large_tag && (_check_flat_names(xml, attrs, @inbounds recs[cur]); large_tag = false)
            ci = @inbounds pstack[end]
            @inbounds spans[ci] = (spans[ci][1], tok_end(token))
            pop!(pstack); pop!(lastchild)

        elseif k === K.TAG_CLOSE
            # The `>` of a start tag, or of an end tag; only a start tag can leave `large_tag` set.
            large_tag && (_check_flat_names(xml, attrs, @inbounds recs[cur]); large_tag = false)

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
            W === :strict && token.has_entities && _check_refs_strict(rawval, strict, true)
            name = _fsub_or_empty(xml, pan_off, pan_len)
            r = @inbounds recs[cur]
            if r.attr_count < _SMALL_ATTRIBUTE_COUNT
                ai = r.attr_first
                for _ in 1:r.attr_count
                    a = @inbounds attrs[ai]
                    _fsub_or_empty(xml, a.name_offset, a.name_len) == name && error("Duplicate attribute: $name")
                    ai += Int32(1)
                end
            else
                large_tag = true   # checked once the tag, or the declaration, closes
            end
            if W === :strict && r.kind === Declaration
                prev = r.attr_count == 0 ? SubString(xml, 1, 0) :
                    _fsub_or_empty(xml, attrs[end].name_offset, attrs[end].name_len)
                _check_decl_attr(codeunit(xml, Int(pan_off)), name, rawval, prev)
            elseif W === :strict
                XMLTokenizer.is_whitespace(codeunit(xml, Int(pan_off))) || _no_attr_space(name)
                _is_xml10_name(name) || _not_a_name("attribute name", name)
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
            large_tag && (_check_flat_names(xml, attrs, @inbounds recs[cur]); large_tag = false)
            W === :strict && (@inbounds recs[cur]).attr_count == 0 && _no_version()
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
            off, len, cr = _flat_value(cmt, _frng(cmt)..., lastcr)
            cr && (len = -len)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(Comment, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.CDATA_CONTENT
            cdata = raw(token, xml)
            W === :strict && _check_chars_strict(cdata)
            off, len, cr = _flat_value(cdata, _frng(cdata)..., lastcr)
            cr && (len = -len)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(CData, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.DOCTYPE_CONTENT
            W !== :lenient && length(pstack) > 1 &&
                error("not well-formed: DOCTYPE declaration inside element content")
            dtd = lstrip(raw(token, xml))                    # mirror _parse: lstrip'd DTD value
            off, len, cr = _flat_value(dtd, _frng(dtd)..., lastcr)
            cr && (len = -len)
            idx = Int32(length(recs) + 1)
            p = _fattach!(recs, pstack, lastchild, idx)
            push!(recs, _FlatRec(DTD, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))
            push!(spans, (open_off, Int32(0)))
            pend = idx

        elseif k === K.PI_OPEN
            target = pi_target(token, xml)
            W === :strict && (_is_xml10_name(target) ||
                              _not_a_name("processing-instruction target", target))
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
                off, len, cr = _flat_value(content, _frng(content)..., lastcr)
                cr && (len = -len)
                @inbounds recs[pend] = _fset_value(recs[pend], off, len)
            end
        end
    end

    if length(pstack) > 1
        open_names = [_fsub_or_empty(xml, recs[i].name_offset, recs[i].name_len) for i in pstack[2:end]]
        error("Unclosed tags: $(join(open_names, ", "))")
    end
    store = FlatStore(xml, recs, attrs, spans)
    W !== :lenient && _check_document_wellformed(children(FlatNode(store, Int32(1))))
    FlatNode(store, Int32(1))
end

# A value `v` at byte offset `off`, of length `len`, as its record keeps it, and whether it
# still holds a CR to normalize (§2.11). Only a value that starts before the document's last
# CR can hold one: a document without one is never searched, nor is a part saved by Excel,
# whose only CR follows its XML declaration. A value that opens on its only CR LF, as the
# indentation of a file saved with CR LF does, is kept from its LF on, and needs no work
# when it is read.
@inline _flat_value(v::SubString{String}, off::Int32, len::Int32, lastcr::Int) =
    off < lastcr ? _flat_value_cr(v, off, len) : (off, len, false)
@noinline function _flat_value_cr(v::SubString{String}, off::Int32, len::Int32)
    j = XMLTokenizer._findbyte(v, UInt8('\r'), 1)
    j === nothing && return (off, len, false)
    j == 1 && len >= 2 && codeunit(v, 2) == 0x0A &&
        XMLTokenizer._findbyte(v, UInt8('\r'), 3) === nothing &&
        return (off + Int32(1), len - Int32(1), false)
    return (off, len, true)
end

@inline _fsub_or_empty(source::String, off::Int32, len::Int32) =
    len > 0 ? (@inbounds _noshift_substring(source, Int(off), Int(len))) : SubString(source, 1, 0)

# The attribute names of record `r`, for the check of a tag with many attributes (parse.jl).
_check_flat_names(source::String, attrs::Vector{_FlatAttr}, r::_FlatRec) =
    _check_unique_names([_fsub_or_empty(source, attrs[ai].name_offset, attrs[ai].name_len)
                         for ai in r.attr_first:(r.attr_first + r.attr_count - Int32(1))])

#-----------------------------------------------------------------------------# parse / read entry points
# The store keeps the `String` as it stands, CRs included, and each value is normalized as
# it is read (§2.11, `_flat_slow`). A document that the declarations of its DOCTYPE rewrite
# is read in that copy, whose line ends the rewrite has normalized: a CR left there comes
# from a character reference, and stays.
function Base.parse(xml::AbstractString, ::Type{FlatNode}; wellformed::Symbol=:structural)
    _check_wellformed(wellformed)
    source, rewritten = _declared_source(_drop_bom(String(xml)))
    return _flat_parse(source, rewritten ? 0 : _last_cr(source), Val(wellformed))
end
Base.parse(::Type{FlatNode}, xml::AbstractString; wellformed::Symbol=:structural) =
    parse(xml, FlatNode; wellformed)
Base.read(filename::AbstractString, ::Type{FlatNode}; wellformed::Symbol=:structural) =
    (_check_wellformed(wellformed); parse(String(_normalize_bom(read(filename))), FlatNode; wellformed))
Base.read(io::IO, ::Type{FlatNode}; wellformed::Symbol=:structural) =
    (_check_wellformed(wellformed); parse(String(_normalize_bom(read(io))), FlatNode; wellformed))

# The position of the last CR of a document read in place, or 0. Two forward searches find
# it when the document holds a single CR, as a part saved by Excel does after its XML
# declaration. With more, the search runs back from the end, where a file saved with CR LF
# has its last one.
function _last_cr(s::String)
    i = XMLTokenizer._findbyte(s, UInt8('\r'), 1)
    i === nothing && return 0
    XMLTokenizer._findbyte(s, UInt8('\r'), i + 1) === nothing && return i
    return findprev(==(UInt8('\r')), codeunits(s), ncodeunits(s))::Int
end

#-----------------------------------------------------------------------------# accessors
@inline nodetype(n::FlatNode) = _rec(n).kind

@inline function tag(n::FlatNode)
    r = _rec(n)
    r.name_len > 0 ? _fsub(n.store, r.name_offset, r.name_len) : nothing
end

# A value whose record asks for work (`value_len < 0`), and the work it asks for (see
# `_FlatRec`): line ends normalized first (§2.11), then references decoded. Out of line, as
# `unescape` is, and given the view and the code alone: each accessor keeps the one test of
# its fast path, and no copy of the record.
@inline _flat_work(r::_FlatRec) = r.kind === Text ? r.name_len : Int32(-1)
@noinline function _flat_slow(raw::SubString{String}, work::Int32)
    s = work < 0 ? _read_eol(raw, false) : raw
    return work == -1 ? s : unescape(s)
end

@inline function value(n::FlatNode)
    r = _rec(n)
    r.value_offset < 0 && return nothing          # absent (empty content is offset ≥ 0, len 0)
    raw = _fsub(n.store, r.value_offset, abs(r.value_len))
    r.value_len < 0 ? _flat_slow(raw, _flat_work(r)) : raw
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
        rawv = _normalize_attr_ws(_fsub(n.store, a.value_offset, abs(a.value_len)))
        push!(out, name => (a.value_len < 0 ? unescape(rawv) : rawv))
        ai += Int32(1)
    end
    out
end

"""
    sourcetext(n::FlatNode) -> SubString

The node's exact raw source slice, markup included — `<tag …>…</tag>` for an element,
`<!--…-->` for a comment, and the whole document for the Document node. Zero-copy: the
store keeps per-record source spans. The slice is taken from the document the store holds:
the `String` given to `parse`, CRs included. The store holds a copy only of a document given
as another string type or with a BOM, and the rewritten copy of one that the declarations of
its DOCTYPE change (see the `LazyNode` method).
"""
function sourcetext(n::FlatNode)
    so, se = @inbounds n.store.spans[n.i]
    _fsub(n.store, so, se - so)
end

"""
    sourcespan(n::FlatNode) -> UnitRange{Int}

O(1): answered straight from the store's per-record source spans. Same contract and
splice idiom as the `LazyNode` method — valid character indices, with
`sourcetext(n) == SubString(source, sourcespan(n))`, where `source` is the string the store
holds (see [`sourcetext`](@ref)).
"""
function sourcespan(n::FlatNode)
    so, se = @inbounds n.store.spans[n.i]
    so == se && return (Int(so) + 1):Int(so)
    (Int(so) + 1):prevind(n.store.source, Int(se) + 1)
end

"""
    splicetext(n::FlatNode, replacement::AbstractString = "") -> String

Same contract as the `LazyNode` method; the node's span is answered in O(1) from the
store. The result is built from the document the store holds (see [`sourcetext`](@ref)),
whose line ends it keeps.
"""
splicetext(n::FlatNode, replacement::AbstractString = "") =
    _splice_span(n.store.source, sourcespan(n), replacement)

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

Base.getindex(n::FlatNode, ::Colon) = children(n)
Base.lastindex(n::FlatNode) = length(n)
Base.only(n::FlatNode) = only(children(n))

"""
    get(n::FlatNode, key::AbstractString, default)

Return the value of attribute `key` on `n`, or `default` if absent. Scans the record's
attribute range and decodes only the matched value — no vector materialized. Use
[`attributes`](@ref) for all pairs at once.
"""
@inline function Base.get(n::FlatNode, key::AbstractString, default)
    r = _rec(n)
    ai = r.attr_first
    for _ in 1:r.attr_count
        a = @inbounds n.store.attrs[ai]
        if _fsub(n.store, a.name_offset, a.name_len) == key
            rawv = _normalize_attr_ws(_fsub(n.store, a.value_offset, abs(a.value_len)))
            return a.value_len < 0 ? unescape(rawv) : rawv
        end
        ai += Int32(1)
    end
    default
end

@inline function Base.getindex(n::FlatNode, key::AbstractString)
    val = get(n, key, nothing)
    val === nothing && throw(KeyError(key))
    val
end

@inline Base.haskey(n::FlatNode, key::AbstractString) = get(n, key, nothing) !== nothing

function Base.keys(n::FlatNode)
    r = _rec(n)
    r.attr_count == 0 && return ()
    out = SubString{String}[]
    sizehint!(out, r.attr_count)
    ai = r.attr_first
    for _ in 1:r.attr_count
        a = @inbounds n.store.attrs[ai]
        push!(out, _fsub(n.store, a.name_offset, a.name_len))
        ai += Int32(1)
    end
    out
end

is_simple(n::FlatNode) = (r = _rec(n);
    r.kind === Element && r.attr_count == 0 && r.first_child != 0 &&
    (c = @inbounds n.store.recs[r.first_child]; c.next_sibling == 0 && (c.kind === Text || c.kind === CData)))

# Both bodies below are `value(::FlatNode)` hand-applied to the child record, and the
# duplication is DELIBERATE — do not factor it into a shared helper. Through any extra
# call depth (a `value(FlatNode(store, first_child))` route, or a shared helper —
# measured with a definition-site `@inline` and with a callsite `@inline`), the
# `@inbounds` chain stops reaching the noshift constructor's own `@boundscheck` (elision
# crosses one level, into inlined callees only): the constructor then inlines *with* its
# checked machinery, and those branches around the view construction re-box the union
# return — 32 B per call on the default-bounds build, invisible under `--check-bounds=yes`,
# which selects the checked reconstruction body. The allocation
# guards enforce both copies (#111, #113, #114).
@inline function is_simple_value(n::FlatNode)
    is_simple(n) || return nothing
    c = @inbounds n.store.recs[_rec(n).first_child]
    c.value_offset < 0 && return nothing
    raw = _fsub(n.store, c.value_offset, abs(c.value_len))
    c.value_len < 0 ? _flat_slow(raw, _flat_work(c)) : raw
end

@inline function simple_value(n::FlatNode)
    is_simple(n) || error("`simple_value` requires a simple node: an Element with no attributes and exactly one Text or CData child. See `is_simple`.")
    c = @inbounds n.store.recs[_rec(n).first_child]
    c.value_offset < 0 && return nothing
    raw = _fsub(n.store, c.value_offset, abs(c.value_len))
    c.value_len < 0 ? _flat_slow(raw, _flat_work(c)) : raw
end

#-----------------------------------------------------------------------------# string_value
function string_value(n::FlatNode)
    store = n.store
    r = _rec(n)
    nt = r.kind
    if nt === Text || nt === CData || nt === Comment || nt === ProcessingInstruction
        return r.value_offset < 0 ? SubString(store.source, 1, 0) : _flat_text(store, r)
    end
    (nt === Element || nt === Document) || _sv_undefined(nt)
    recs = store.recs
    stop = _flat_subtree_end(recs, n.i)
    k = 0
    m = 0
    first = Int32(0)
    for j in (n.i + Int32(1)):(stop - Int32(1))
        c = @inbounds recs[j]
        _flat_counts(c) || continue
        k == 0 && (first = j)
        k += 1
        m += c.value_len >= 0 ? Int(c.value_len) : _flat_slow_size(store, c)
    end
    k == 0 && return SubString(store.source, 1, 0)
    k == 1 && return _flat_text(store, @inbounds recs[first])
    out = Base._string_n(m)
    i = 1
    for j in first:(stop - Int32(1))
        c = @inbounds recs[j]
        _flat_counts(c) || continue
        if c.value_len >= 0
            i = _sv_put!(out, i, _fsub(store, c.value_offset, c.value_len))
        else
            i = _flat_slow_put!(out, i, store, c)
        end
    end
    return SubString(_sv_check(out, i))
end

# The records are stored in document order, so the subtree of record `i` is the run of
# records after it, up to the next sibling of the nearest ancestor-or-self that has one.
@inline function _flat_subtree_end(recs::Vector{_FlatRec}, i::Int32)
    j = i
    while j != 0
        r = @inbounds recs[j]
        r.next_sibling != 0 && return r.next_sibling
        j = r.parent
    end
    return Int32(length(recs) + 1)
end

# A text of the subtree that counts: a `Text` or a `CData` inside an element. Record 1 is
# the document, whose own texts are not text for XPath.
@inline _flat_counts(c::_FlatRec) = (c.kind === Text || c.kind === CData) && c.parent != 1

# A record's text as `value` gives it. A text that asks for work is, for the two passes of
# `string_value`, normalized when its record says so, then, for a Text, decoded into the
# scratch of `unescape`: its size first, then its bytes.
@inline function _flat_text(store::FlatStore, c::_FlatRec)
    raw = _fsub(store, c.value_offset, abs(c.value_len))
    return c.value_len < 0 ? _flat_slow(raw, _flat_work(c)) : raw
end
@inline function _flat_slow_raw(store::FlatStore, c::_FlatRec)
    raw = _fsub(store, c.value_offset, -c.value_len)
    return _flat_work(c) < 0 ? _read_eol(raw, false) : raw
end
function _flat_slow_size(store::FlatStore, c::_FlatRec)
    s = _flat_slow_raw(store, c)
    _flat_work(c) == -1 && return ncodeunits(s)
    return _decode_to_scratch!(codeunits(s), ncodeunits(s))[2]
end
function _flat_slow_put!(out::String, i::Int, store::FlatStore, c::_FlatRec)
    s = _flat_slow_raw(store, c)
    _flat_work(c) == -1 && return _sv_put!(out, i, s)
    buf, len, _ = _decode_to_scratch!(codeunits(s), ncodeunits(s))
    return _sv_put!(out, i, buf, len)
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
