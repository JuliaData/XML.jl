
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

#-----------------------------------------------------------------------------# parse
# A leading U+FEFF (BOM as a character) isn't content — drop it so a BOM'd in-memory string
# parses cleanly. (The read path strips the BOM bytes via _normalize_bom; this covers
# parse(::AbstractString), where the bytes have already decoded to a U+FEFF char.)
_drop_bom(s::String)::String = startswith(s, '\ufeff') ? s[nextind(s, 1):end] : s

# Generic (type-preserving) form so a leading U+FEFF is also dropped inside the type-parametric
# Cursor constructor (SubString today, StringView when mmap lands), not only on the String
# parse(_, Node)/LazyNode paths — keeping all three readers consistent on a BOM'd string.
_drop_bom(s::AbstractString) = startswith(s, Char(0xFEFF)) ? SubString(s, nextind(s, firstindex(s))) : s

Base.parse(::Type{Node}, xml::AbstractString; wellformed::Symbol=:structural) = parse(xml, Node; wellformed)

function Base.parse(xml::AbstractString, ::Type{Node}; wellformed::Symbol=:structural)
    _parse(_drop_bom(String(xml)), String, unescape, Val(wellformed))
end

function Base.parse(xml::AbstractString, ::Type{Node{SubString{String}}}; wellformed::Symbol=:structural)
    _parse(_drop_bom(String(xml)), SubString{String}, identity, Val(wellformed))
end

# Convert a parser substring to the requested storage type — copy to a fresh String, or
# keep the zero-copy SubString view.
_to(::Type{String}, s::AbstractString) = String(s)
_to(::Type{SubString{String}}, s::SubString{String}) = s

# Collapse an empty Vector to `nothing` so Node fields store "absent" canonically.
_nothingify(v::Vector) = isempty(v) ? nothing : v

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
# reference-vs-raw asymmetry. DCE'd off the :strict path, so :lenient/:structural pay nothing.
function _check_chars_strict(s::AbstractString)
    for c in s
        _is_xml_char(UInt32(c)) ||
            error("not well-formed: character U+$(uppercase(string(UInt32(c); base = 16, pad = 4))) is outside the legal XML range (XML 1.0 §2.2)")
    end
end

# `:strict` only: reject any numeric character reference whose code point is outside the XML Char
# range. Gated + DCE'd off the :strict path, and only called when a token actually carries
# entities, so :lenient/:structural pay nothing.
function _check_charrefs_strict(s::AbstractString)
    for m in eachmatch(r"&#([xX]?)([0-9a-fA-F]+);", s)
        cp = tryparse(UInt32, m[2]; base = isempty(m[1]) ? 10 : 16)
        (cp === nothing || !_is_xml_char(cp)) &&
            error("not well-formed: illegal character reference \"&#$(m[1])$(m[2]);\"")
    end
end

# Token-stream → Node{S} builder. `convert_text` is `unescape` for parsed content (with entity
# decoding) and `identity` for zero-copy SubString parsing where the caller keeps raw escapes.
# `Val{W}` is the well-formedness level (:lenient / :structural / :strict); its checks compile
# away on :lenient.
function _parse(xml::String, ::Type{S}, convert_text::F, ::Val{W}) where {S, F, W}
    tags = S[]
    attrs_stack = Vector{Pair{S,S}}[]
    children_stack = Vector{Vector{Node{S}}}()
    push!(children_stack, Node{S}[])

    pending_attr_name = SubString(xml, 1, 0)
    decl_attrs = nothing
    pending_pi_tag = SubString(xml, 1, 0)
    pending_pi_value = nothing

    for token in tokenize(xml)
        k = token.kind

        if k === TokenKinds.TEXT
            rawtext = raw(token, xml)
            W === :strict && _check_chars_strict(rawtext)
            W === :strict && token.has_entities && _check_charrefs_strict(rawtext)
            v = _text_value(S, rawtext, token.has_entities, convert_text)
            push!(last(children_stack), Node{S}(Text, nothing, nothing, v, nothing))

        elseif k === TokenKinds.OPEN_TAG
            nm = tag_name(token, xml)
            W !== :lenient && (isempty(nm) || !_is_name_start(first(nm))) &&
                error("not well-formed: invalid element name \"$nm\"")
            push!(tags, _to(S, nm))
            push!(attrs_stack, Pair{S,S}[])
            push!(children_stack, Node{S}[])

        elseif k === TokenKinds.SELF_CLOSE
            t = pop!(tags)
            a = pop!(attrs_stack)
            pop!(children_stack)
            push!(last(children_stack), Node{S}(Element, t, _nothingify(a), nothing, nothing))

        elseif k === TokenKinds.CLOSE_TAG
            close_name = tag_name(token, xml)
            isempty(tags) && error("Closing tag </$close_name> with no matching open tag.")
            t = pop!(tags)
            t == close_name || error("Mismatched tags: expected </$t>, got </$close_name>.")
            a = pop!(attrs_stack)
            c = pop!(children_stack)
            push!(last(children_stack), Node{S}(Element, t, _nothingify(a), nothing, isempty(c) ? nothing : c))

        elseif k === TokenKinds.ATTR_NAME
            pending_attr_name = raw(token, xml)

        elseif k === TokenKinds.ATTR_VALUE
            rawval = attr_value(token, xml)
            W !== :lenient && occursin('<', rawval) && error("not well-formed: '<' in attribute value (XML 1.0 §3.1)")
            W === :strict && _check_chars_strict(rawval)
            W === :strict && token.has_entities && _check_charrefs_strict(rawval)
            val = _text_value(S, rawval, token.has_entities, convert_text)
            name = _to(S, pending_attr_name)
            if decl_attrs !== nothing
                any(p -> first(p) == name, decl_attrs) && error("Duplicate attribute: $name")
                push!(decl_attrs, name => val)
            elseif !isempty(attrs_stack)
                any(p -> first(p) == name, last(attrs_stack)) && error("Duplicate attribute: $name")
                push!(last(attrs_stack), name => val)
            end

        elseif k === TokenKinds.XML_DECL_OPEN
            decl_attrs = Pair{S,S}[]

        elseif k === TokenKinds.XML_DECL_CLOSE
            W !== :lenient && length(children_stack) > 1 &&
                error("not well-formed: XML declaration inside element content")
            a = isempty(decl_attrs) ? nothing : decl_attrs
            push!(last(children_stack), Node{S}(Declaration, nothing, a, nothing, nothing))
            decl_attrs = nothing

        elseif k === TokenKinds.COMMENT_CONTENT
            cmt = raw(token, xml)
            W === :strict && _check_chars_strict(cmt)
            W === :strict && occursin("--", cmt) && error("not well-formed: \"--\" within a comment")
            W === :strict && endswith(cmt, '-') && error("not well-formed: \"-\" immediately before \"-->\" in a comment (XML 1.0 §2.5)")
            push!(last(children_stack), Node{S}(Comment, nothing, nothing, _to(S, cmt), nothing))

        elseif k === TokenKinds.CDATA_CONTENT
            cdata = raw(token, xml)
            W === :strict && _check_chars_strict(cdata)
            push!(last(children_stack), Node{S}(CData, nothing, nothing, _to(S, cdata), nothing))

        elseif k === TokenKinds.DOCTYPE_CONTENT
            W !== :lenient && length(children_stack) > 1 &&
                error("not well-formed: DOCTYPE declaration inside element content")
            push!(last(children_stack), Node{S}(DTD, nothing, nothing, _to(S, lstrip(raw(token, xml))), nothing))

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
            push!(last(children_stack), Node{S}(ProcessingInstruction, _to(S, pending_pi_tag), nothing, pending_pi_value, nothing))
        end
    end

    !isempty(tags) && error("Unclosed tags: $(join(tags, ", "))")
    doc_children = only(children_stack)
    W !== :lenient && _check_document_wellformed(doc_children)
    Node{S}(Document, nothing, nothing, nothing, isempty(doc_children) ? nothing : doc_children)
end

