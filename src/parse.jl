
# Honor a leading byte-order mark (XML 1.0 §4.3.3): transcode UTF-16 (LE/BE) to UTF-8
# and strip a UTF-8 BOM so the parser always sees UTF-8. Ported from #65 (was src/raw.jl).
function _normalize_bom(data::Vector{UInt8})
    n = length(data)
    if n >= 2 && data[1] == 0xFF && data[2] == 0xFE          # UTF-16 LE
        isodd(n) && error("malformed UTF-16: odd number of bytes after the BOM (XML 1.0 §4.3.3)")
        return Vector{UInt8}(transcode(String, reinterpret(UInt16, data[3:end])))
    elseif n >= 2 && data[1] == 0xFE && data[2] == 0xFF      # UTF-16 BE
        isodd(n) && error("malformed UTF-16: odd number of bytes after the BOM (XML 1.0 §4.3.3)")
        return Vector{UInt8}(transcode(String, bswap.(reinterpret(UInt16, data[3:end]))))
    elseif n >= 3 && data[1] == 0xEF && data[2] == 0xBB && data[3] == 0xBF  # UTF-8 BOM
        return data[4:end]
    end
    # No BOM matched. A NUL in the first two bytes means UTF-16/UTF-32 without a BOM — not
    # well-formed XML (§4.3.3). Without this, :structural still rejects it downstream, but with a
    # cryptic "invalid element name" (the interleaved NULs derail tokenization); this names the real
    # cause. Two comparisons, no false positives (well-formed UTF-8 XML can't contain 0x00) — vs
    # isvalid(String, data), which would be an O(n) hot-path scan.
    n >= 2 && (data[1] == 0x00 || data[2] == 0x00) &&
        error("UTF-16 without a BOM is not well-formed (XML 1.0 §4.3.3)")
    return data
end

Base.read(filename::AbstractString, ::Type{Node}; wellformed::Symbol=:structural) = parse(String(_normalize_bom(read(filename))), Node; wellformed)
Base.read(io::IO, ::Type{Node}; wellformed::Symbol=:structural) = parse(String(_normalize_bom(read(io))), Node; wellformed)

# Cursor shares the tree readers' entry points (#89): same argument order, same byte-level
# BOM normalization. The Cursor(str) constructor alone only drops an already-decoded U+FEFF,
# so a UTF-16 file needs this path (like read(_, Node)) to be transcoded.
Base.read(filename::AbstractString, ::Type{Cursor}) = Cursor(String(_normalize_bom(read(filename))))
Base.read(io::IO, ::Type{Cursor}) = Cursor(String(_normalize_bom(read(io))))
Base.parse(xml::AbstractString, ::Type{Cursor}) = Cursor(xml)

#-----------------------------------------------------------------------------# parse
# A leading U+FEFF (BOM as a character) isn't content — drop it so a BOM'd in-memory string
# parses cleanly. (The read path strips the BOM bytes via _normalize_bom; this covers
# parse(::AbstractString), where the bytes have already decoded to a U+FEFF char.)
_drop_bom(s::String)::String = startswith(s, '\ufeff') ? s[nextind(s, 1):end] : s

# Generic (type-preserving) form so a leading U+FEFF is also dropped inside the type-parametric
# Cursor constructor (a `SubString`, or a `StringView` over a mapped file), not only on the String
# parse(_, Node)/LazyNode paths — keeping all three readers consistent on a BOM'd string.
_drop_bom(s::AbstractString) = startswith(s, Char(0xFEFF)) ? SubString(s, nextind(s, firstindex(s))) : s

Base.parse(::Type{Node}, xml::AbstractString; wellformed::Symbol=:structural) = parse(xml, Node; wellformed)

function Base.parse(xml::AbstractString, ::Type{Node}; wellformed::Symbol=:structural)
    _parse(_expand_entities(_normalize_input_eol(_drop_bom(String(xml)))), String, unescape, Val(wellformed))
end

function Base.parse(xml::AbstractString, ::Type{Node{SubString{String}}}; wellformed::Symbol=:structural)
    _parse(_expand_entities(_normalize_input_eol(_drop_bom(String(xml)))), SubString{String}, identity, Val(wellformed))
end

# Convert a parser substring to the requested storage type — copy to a fresh String, or
# keep the zero-copy SubString view.
_to(::Type{String}, s::AbstractString) = String(s)
_to(::Type{SubString{String}}, s::SubString{String}) = s

# Slice the run `scratch[mark+1:end]` out as one exact-size Vector — or `nothing` when the
# run is empty, so Node fields store "absent" canonically and the empty case allocates
# nothing at all — then truncate the scratch back to the mark (#107).
function _take_slice!(scratch::Vector{T}, mark::Int) where {T}
    n = length(scratch)
    n == mark && return nothing
    out = scratch[(mark + 1):n]
    resize!(scratch, mark)
    out
end

# Decode the raw bytes of a TEXT/ATTR_VALUE token into the parser's storage type. When the
# tokenizer guarantees no `&` was seen (`has_entities=false`), we skip the entity-decode
# pass entirely. The `convert_text=identity` specialization (SubString parse) skips the
# runtime branch as well — both arms would return the same value.
@inline _text_value(::Type{S}, raw, _, ::typeof(identity)) where {S} = _to(S, raw)
@inline _text_value(::Type{S}, raw, has_entities, convert_text::F) where {S, F} =
    has_entities ? convert_text(raw) : _to(S, raw)

# An XML NameStartChar (lenient on Unicode, mirroring NAME_BYTE_TABLE): a letter, `_`, `:`, or
# any non-ASCII char — but NOT a digit / `-` / `.` (those are valid NameChars, just not first).
@inline _is_name_start(c::Char) =
    ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '_' || c == ':' || !isascii(c)

# Document-shape well-formedness (`:structural`/`:strict`): exactly one root element (prolog
# markup with no root is rejected; an empty `""` or a whitespace-only input is still accepted — the
# former an empty Document, the latter a Document whose only child is whitespace Text), any
# top-level Text must be whitespace only, and a DOCTYPE must be a single declaration in the prolog
# (before the root). (`:lenient` skips this — gated + DCE'd.)
function _check_document_wellformed(children)
    nroots = 0
    ndtds = 0
    has_markup = false   # a Comment / PI / Declaration / CData / DTD at the top level
    for (idx, c) in enumerate(children)
        nt = nodetype(c)
        if nt === Element
            nroots += 1
        elseif nt === Text
            isempty(strip(value(c))) || error("not well-formed: non-whitespace text at the top level")
        else
            has_markup = true
            if nt === DTD
                ndtds += 1
                nroots > 0 && error("not well-formed: DOCTYPE must precede the root element")
            elseif nt === Declaration
                # §2.8: the XML declaration must be the very first thing in the document. Only the
                # first child may be a Declaration; a second (or any later) one is misplaced.
                idx == 1 || error("not well-formed: the XML declaration must be the first thing in the document (XML 1.0 §2.8)")
            end
        end
    end
    nroots > 1 && error("not well-formed: multiple root elements (found $nroots)")
    ndtds > 1 && error("not well-formed: multiple DOCTYPE declarations (found $ndtds)")
    nroots == 0 && has_markup && error("not well-formed: no root element")
end

# XML §2.2 Char production — the code points a character reference may legally denote. Stricter
# than Julia's `isvalid(Char, cp)`, which accepts #x0 and other C0 controls that XML forbids.
_is_xml_char(cp::Integer) =
    cp == 0x9 || cp == 0xA || cp == 0xD ||
    (0x20 <= cp <= 0xD7FF) || (0xE000 <= cp <= 0xFFFD) || (0x10000 <= cp <= 0x10FFFF)

# `:strict` only: reject a raw character outside the XML §2.2 Char range (e.g. NUL / C0 controls).
# Without this, a literal illegal character passes while its &#...; reference form is rejected — a
# reference-vs-raw asymmetry. DCE'd off the :strict path, so :lenient/:structural cost nothing.
#
# The range is a byte-level property below 0x80: a byte is legal unless it is a control other than
# tab, line feed and carriage return. So the check reads the code units and decodes only where a
# byte at or above 0x80 starts a multi-byte sequence. Two paths, by span length. Most spans a
# document yields are short — an attribute value, the white space between two tags — and a span
# of at most 16 bytes is read as two 8-byte words tested without a loop or a data-dependent
# branch; a longer span is read a block at a time, by a reduction the compiler vectorises. On both
# paths a flagged byte is followed by a decoding walk over the span, the string's own `Char`
# iteration, so the verdict, the message and the error on a malformed sequence are those of a
# `for c in s` loop.
const _CHAR_SCAN_BLOCK = 64
const _W_HI = 0x8080808080808080
const _W_01 = 0x0101010101010101
const _W_09 = 0x0909090909090909
const _W_0A = 0x0a0a0a0a0a0a0a0a
const _W_0D = 0x0d0d0d0d0d0d0d0d
const _W_20 = 0x2020202020202020

_check_chars_strict(s::AbstractString) = _check_chars_blocks(s)

# A span of a `String` document. Up to 16 bytes, the two words are read from the parent string,
# where the guard keeps them inside its code units whatever the span's length; `ltoh` makes the
# first byte of the span the low byte of the word, and the bytes past the span are replaced by
# spaces before the test.
@inline function _check_chars_strict(s::SubString{String})
    n = ncodeunits(s)
    parent = s.string
    if n <= 16 && s.offset + 16 <= ncodeunits(parent)
        GC.@preserve parent begin
            p = pointer(parent) + s.offset
            x1 = ltoh(unsafe_load(Ptr{UInt64}(p)))
            x2 = ltoh(unsafe_load(Ptr{UInt64}(p + 8)))
        end
        r1 = min(n, 8)
        r2 = n - r1
        m1 = (UInt64(1) << (8r1)) - 1        # a shift by 64 gives 0, so eight bytes give all ones
        m2 = (UInt64(1) << (8r2)) - 1
        x1 = (x1 & m1) | (~m1 & _W_20)
        x2 = (x2 & m2) | (~m2 & _W_20)
        (_word_flagged(x1) | _word_flagged(x2)) || return nothing
        _check_chars_decoding(s, codeunits(s), 1, n)
        return nothing
    end
    return _check_chars_blocks(s)
end

# `true` when a byte of the word is at or above 0x80, or a control other than tab, line feed and
# carriage return. Each per-byte test is exact for a byte below 0x80; a byte at or above 0x80 is
# flagged by its high bit whatever the other tests make of it.
@inline function _word_flagged(x::UInt64)
    hi = x & _W_HI
    lt = ~((x | _W_HI) - _W_20) & _W_HI
    is9 = ~(((x ⊻ _W_09) | _W_HI) - _W_01) & _W_HI
    is10 = ~(((x ⊻ _W_0A) | _W_HI) - _W_01) & _W_HI
    is13 = ~(((x ⊻ _W_0D) | _W_HI) - _W_01) & _W_HI
    return (hi | (lt & ~(is9 | is10 | is13))) != 0
end

@noinline function _check_chars_blocks(s::AbstractString)
    cu = codeunits(s)
    n = length(cu)
    i = 1
    while i <= n
        j = min(i + _CHAR_SCAN_BLOCK - 1, n)
        i = _ascii_block_legal(cu, i, j) ? j + 1 : _check_chars_decoding(s, cu, i, j)
    end
    return nothing
end

# `true` when every byte of `cu[i:j]` is a legal ASCII character: below 0x80 (a byte at or above
# starts or continues a multi-byte sequence, which the decode judges) and not a control other than
# tab, line feed and carriage return. A reduction without an early exit, which the compiler
# vectorises.
@inline function _ascii_block_legal(cu, i::Int, j::Int)
    flagged = false
    @inbounds for k in i:j
        b = cu[k]
        flagged |= (b >= 0x80) | ((b < 0x20) & (b != 0x09) & (b != 0x0A) & (b != 0x0D))
    end
    return !flagged
end

# The decoding walk over `cu[i:j]`, taken after a flagged byte. An ASCII byte is judged in place;
# at a byte at or above 0x80 the string's `Char` iteration decodes the sequence from that index,
# which may run past `j`. Returns the index after the last byte consumed.
@noinline function _check_chars_decoding(s::AbstractString, cu, i::Int, j::Int)
    k = i
    @inbounds while k <= j
        b = cu[k]
        if b < 0x80
            (b >= 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) || _char_range_error(UInt32(b))
            k += 1
        else
            c, k = @something iterate(s, k)
            cp = UInt32(c)      # raises `Base.InvalidCharError` on a malformed sequence, as `for c in s` does
            _is_xml_char(cp) || _char_range_error(cp)
        end
    end
    return k
end

@noinline _char_range_error(cp::UInt32) =
    error("not well-formed: character U+$(uppercase(string(cp; base = 16, pad = 4))) is outside the legal XML range (XML 1.0 §2.2)")

# `:strict` only, one pass over a span's references, character and named alike. Gated + DCE'd off
# the :strict path and called only when a token carries entities, so :lenient/:structural cost
# nothing. The pass reads code units: every byte where it stops — `&`, `#`, `x`, a digit, `;`, the
# byte after a name — is ASCII, hence a character boundary, since a name takes every byte at or
# above 0x80 as its own; a span it accepts allocates nothing, and only a rejected reference is
# copied, into its message. A character reference is rejected when its digit run denotes no code
# point of the XML Char range; the run is read on the hexadecimal alphabet in both forms, so a
# decimal form carrying a letter is rejected too. A named reference
# is checked only when `names` holds, and the test is then a membership one: `_expand_entities`
# has already replaced every reference it could resolve, so a name arriving here that is not
# predefined has no replacement text behind it (XML 1.0 §4.1, the "Entity Declared"
# well-formedness constraint). A `&` that starts neither form — one followed by no name, or by a
# name or a digit run without its `;` — goes unchecked, which costs a missed rejection and never
# a wrong one.
function _check_refs_strict(s::AbstractString, names::Bool)
    cu = codeunits(s)
    n = length(cu)
    i = findnext(==(UInt8('&')), cu, 1)
    while i !== nothing
        next = i + 1
        if i + 1 <= n && @inbounds(cu[i + 1]) == UInt8('#')
            j, cp = _charref_at(cu, i, n)
            if j > 0
                _is_xml_char(cp) ||
                    error("not well-formed: illegal character reference \"", String(cu[i:j]), "\"")
                next = j + 1
            end
        else
            j = _name_end(cu, i + 1, n)
            if j > 0
                if names
                    _, len = _predefined_at(cu, i, n)
                    len == 0 && error("not well-formed: reference to undeclared entity \"", String(cu[i:j]), "\" (XML 1.0 §4.1)")
                end
                next = j + 1
            end
        end
        i = findnext(==(UInt8('&')), cu, next)   # next ≤ n + 1, where findnext answers `nothing`
    end
end

# Token-stream → Node{S} builder. `convert_text` is `unescape` for parsed content (with entity
# decoding) and `identity` for zero-copy SubString parsing where the caller keeps raw escapes.
# `Val{W}` is the well-formedness level (:lenient / :structural / :strict); its checks compile
# away on :lenient.
function _parse(xml::String, ::Type{S}, convert_text::F, ::Val{W}) where {S, F, W}
    # `:strict` decides whether the named-reference check compiles in at all; the document's
    # own shape decides whether it may fire (§4.1).
    check_names = W === :strict && _entity_wfc_applies(xml)
    tags = S[]
    # The value-stack discipline of stack parsers (#107): constituents accumulate on two
    # parse-wide scratch vectors, integer marks delimit the currently-open element's run,
    # and each close slices its exact-size run back out — no per-element vector, no
    # push!-growth churn, and an empty run materializes as `nothing` without allocating.
    scratch_attrs = Pair{S,S}[]
    scratch_children = Node{S}[]
    attr_marks = Int[]
    child_marks = Int[]

    pending_attr_name = SubString(xml, 1, 0)
    decl_attrs = nothing
    pending_pi_tag = SubString(xml, 1, 0)
    pending_pi_value = nothing

    for token in tokenize(xml)
        k = token.kind

        if k === TokenKinds.TEXT
            rawtext = raw(token, xml)
            W === :strict && _check_chars_strict(rawtext)
            W === :strict && token.has_entities && _check_refs_strict(rawtext, check_names)
            v = _text_value(S, rawtext, token.has_entities, convert_text)
            push!(scratch_children, Node{S}(Text, nothing, nothing, v, nothing))

        elseif k === TokenKinds.OPEN_TAG
            nm = tag_name(token, xml)
            W !== :lenient && (isempty(nm) || !_is_name_start(first(nm))) &&
                error("not well-formed: invalid element name \"$nm\"")
            push!(tags, _to(S, nm))
            push!(attr_marks, length(scratch_attrs))
            push!(child_marks, length(scratch_children))

        elseif k === TokenKinds.SELF_CLOSE
            t = pop!(tags)
            a = _take_slice!(scratch_attrs, pop!(attr_marks))
            pop!(child_marks)   # a self-closing element cannot have accumulated children
            push!(scratch_children, Node{S}(Element, t, a, nothing, nothing))

        elseif k === TokenKinds.CLOSE_TAG
            close_name = tag_name(token, xml)
            isempty(tags) && error("Closing tag </$close_name> with no matching open tag.")
            t = pop!(tags)
            t == close_name || error("Mismatched tags: expected </$t>, got </$close_name>.")
            a = _take_slice!(scratch_attrs, pop!(attr_marks))
            c = _take_slice!(scratch_children, pop!(child_marks))
            push!(scratch_children, Node{S}(Element, t, a, nothing, c))

        elseif k === TokenKinds.ATTR_NAME
            pending_attr_name = raw(token, xml)

        elseif k === TokenKinds.ATTR_VALUE
            rawval = attr_value(token, xml)
            W !== :lenient && occursin('<', rawval) && error("not well-formed: '<' in attribute value (XML 1.0 §3.1)")
            W === :strict && _check_chars_strict(rawval)
            W === :strict && token.has_entities && _check_refs_strict(rawval, check_names)
            val = _text_value(S, _normalize_attr_ws(rawval), token.has_entities, convert_text)
            name = _to(S, pending_attr_name)
            if decl_attrs !== nothing
                any(p -> first(p) == name, decl_attrs) && error("Duplicate attribute: $name")
                push!(decl_attrs, name => val)
            elseif !isempty(attr_marks)
                for i in (attr_marks[end] + 1):length(scratch_attrs)
                    first(scratch_attrs[i]) == name && error("Duplicate attribute: $name")
                end
                push!(scratch_attrs, name => val)
            end

        elseif k === TokenKinds.XML_DECL_OPEN
            decl_attrs = Pair{S,S}[]

        elseif k === TokenKinds.XML_DECL_CLOSE
            W !== :lenient && !isempty(child_marks) &&
                error("not well-formed: XML declaration inside element content")
            a = isempty(decl_attrs) ? nothing : decl_attrs
            push!(scratch_children, Node{S}(Declaration, nothing, a, nothing, nothing))
            decl_attrs = nothing

        elseif k === TokenKinds.COMMENT_CONTENT
            cmt = raw(token, xml)
            W === :strict && _check_chars_strict(cmt)
            W === :strict && occursin("--", cmt) && error("not well-formed: \"--\" within a comment")
            W === :strict && endswith(cmt, '-') && error("not well-formed: \"-\" immediately before \"-->\" in a comment (XML 1.0 §2.5)")
            push!(scratch_children, Node{S}(Comment, nothing, nothing, _to(S, cmt), nothing))

        elseif k === TokenKinds.CDATA_CONTENT
            cdata = raw(token, xml)
            W === :strict && _check_chars_strict(cdata)
            push!(scratch_children, Node{S}(CData, nothing, nothing, _to(S, cdata), nothing))

        elseif k === TokenKinds.DOCTYPE_CONTENT
            W !== :lenient && !isempty(child_marks) &&
                error("not well-formed: DOCTYPE declaration inside element content")
            push!(scratch_children, Node{S}(DTD, nothing, nothing, _to(S, lstrip(raw(token, xml))), nothing))

        elseif k === TokenKinds.PI_OPEN
            pending_pi_tag = pi_target(token, xml)
            W === :strict && (isempty(pending_pi_tag) || !_is_name_start(first(pending_pi_tag))) &&
                error("not well-formed: invalid processing-instruction target \"$pending_pi_tag\"")
            pending_pi_value = nothing

        elseif k === TokenKinds.PI_CONTENT
            content = lstrip(raw(token, xml))
            W === :strict && _check_chars_strict(content)
            pending_pi_value = isempty(content) ? nothing : _to(S, content)

        elseif k === TokenKinds.PI_CLOSE
            push!(scratch_children, Node{S}(ProcessingInstruction, _to(S, pending_pi_tag), nothing, pending_pi_value, nothing))
        end
    end

    !isempty(tags) && error("Unclosed tags: $(join(tags, ", "))")
    # Slice the document level out too: the scratch keeps its historical peak capacity,
    # which must not be retained by the returned tree.
    doc_children = _take_slice!(scratch_children, 0)
    W !== :lenient && doc_children !== nothing && _check_document_wellformed(doc_children)
    Node{S}(Document, nothing, nothing, nothing, doc_children)
end

