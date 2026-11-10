
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

# The readers compare the `wellformed` level only with `:lenient` and `:strict`, so another
# symbol would get the checks of `:structural` without notice. Every entry point checks it
# first; `read` does so before it reads the document.
function _check_wellformed(wellformed::Symbol)
    wellformed === :lenient || wellformed === :structural || wellformed === :strict ||
        throw(ArgumentError("wellformed must be :lenient, :structural or :strict, not $(repr(wellformed))"))
    return nothing
end

Base.read(filename::AbstractString, ::Type{Node}; wellformed::Symbol=:structural) =
    (_check_wellformed(wellformed); parse(String(_normalize_bom(read(filename))), Node; wellformed))
Base.read(io::IO, ::Type{Node}; wellformed::Symbol=:structural) =
    (_check_wellformed(wellformed); parse(String(_normalize_bom(read(io))), Node; wellformed))

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
    _check_wellformed(wellformed)
    _parse(_apply_declarations(_normalize_input_eol(_drop_bom(String(xml)))), String, unescape, Val(wellformed))
end

function Base.parse(xml::AbstractString, ::Type{Node{SubString{String}}}; wellformed::Symbol=:structural)
    _check_wellformed(wellformed)
    _parse(_apply_declarations(_normalize_input_eol(_drop_bom(String(xml)))), SubString{String}, identity, Val(wellformed))
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

# Under `:strict`, a name follows [5] `Name ::= NameStartChar (NameChar)*` of XML 1.0 §2.3. The
# tokenizer ends a name at the first ASCII byte that `NAME_BYTE_TABLE` leaves out
# (`read_open_tag_start`, `read_in_tag`, `read_pi_start`), so an ASCII byte after the first one is
# a NameChar already: the first byte is tested, and a name with a byte beyond ASCII is decoded from
# that byte on.
@inline _is_ascii_name_start(b::UInt8) =
    (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
    b == UInt8('_') || b == UInt8(':')
@inline function _is_xml10_name(s::AbstractString)
    cu = codeunits(s)
    isempty(cu) && return false
    b = @inbounds cu[1]
    b < 0x80 && !_is_ascii_name_start(b) && return false
    @inbounds for i in eachindex(cu)
        cu[i] >= 0x80 && return _xml10_name_bytes(s, i, i == 1)
    end
    return true
end

# [4] NameStartChar and [4a] NameChar beyond ASCII, the ranges that `_NAME_START_RANGES` and
# `_NAME_CHAR_RANGES` hold for `xpath`, as tests on the code point: U+00C0 to U+1FFF all start a
# name but for U+00D7, U+00F7, U+0300-U+036F and U+037E, and U+3001-U+D7FF, the most common range
# above them, comes first. The testset "Spec 2.3" checks them against the two tuples at each bound.
@inline function _is_name_start_cp(cp::UInt32)
    if cp < 0x2000
        cp < 0x300 && return cp >= 0xC0 && cp != 0xD7 && cp != 0xF7
        return cp >= 0x370 && cp != 0x37E
    end
    (0x3001 <= cp <= 0xD7FF) && return true
    return (0x200C <= cp <= 0x200D) || (0x2070 <= cp <= 0x218F) || (0x2C00 <= cp <= 0x2FEF) ||
           (0xF900 <= cp <= 0xFDCF) || (0xFDF0 <= cp <= 0xFFFD) || (0x10000 <= cp <= 0xEFFFF)
end
@inline _is_name_char_only_cp(cp::UInt32) =
    cp == 0xB7 || (0x300 <= cp <= 0x36F) || (0x203F <= cp <= 0x2040)
@inline _is_utf8_cont(b::UInt8) = (b & 0xC0) == 0x80

# The bytes of a name from index i on, its first character at i if `isfirst`. Each character beyond
# ASCII is decoded from bytes that must be well-formed UTF-8, then tested on its code point. It
# takes the name and not its `codeunits`: passing that wrapper to a function left out of line made
# every call of `_is_xml10_name` build it in memory, under a GC frame, ASCII names included.
@noinline function _xml10_name_bytes(s::AbstractString, i::Int, isfirst::Bool)
    cu = codeunits(s)
    n = length(cu)
    @inbounds while i <= n
        b = cu[i]
        if b < 0x80
            i += 1
            isfirst = false
            continue
        end
        if b < 0xC2                         # a continuation byte, or an overlong two-byte lead
            return false
        elseif b < 0xE0
            i + 1 <= n || return false
            b2 = cu[i+1]
            _is_utf8_cont(b2) || return false
            cp = (UInt32(b & 0x1F) << 6) | UInt32(b2 & 0x3F)
            i += 2
        elseif b < 0xF0
            i + 2 <= n || return false
            b2 = cu[i+1]; b3 = cu[i+2]
            (_is_utf8_cont(b2) && _is_utf8_cont(b3)) || return false
            cp = (UInt32(b & 0x0F) << 12) | (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)
            (cp >= 0x800 && !(0xD800 <= cp <= 0xDFFF)) || return false
            i += 3
        elseif b < 0xF5
            i + 3 <= n || return false
            b2 = cu[i+1]; b3 = cu[i+2]; b4 = cu[i+3]
            (_is_utf8_cont(b2) && _is_utf8_cont(b3) && _is_utf8_cont(b4)) || return false
            cp = (UInt32(b & 0x07) << 18) | (UInt32(b2 & 0x3F) << 12) | (UInt32(b3 & 0x3F) << 6) |
                 UInt32(b4 & 0x3F)
            (0x10000 <= cp <= 0x10FFFF) || return false
            i += 4
        else
            return false
        end
        (_is_name_start_cp(cp) || (!isfirst && _is_name_char_only_cp(cp))) || return false
        isfirst = false
    end
    return true
end
@noinline _not_a_name(what::String, name::AbstractString) =
    error("not well-formed: invalid ", what, " \"", name, "\" (XML 1.0 §2.3)")

# XML 1.0 §2.6: [17] reserves the processing-instruction target `xml` in every case, and
# [16] puts white space between a target and the rest of the instruction, which the
# tokenizer gives as the content: empty, or starting with white space.
_is_reserved_pi_target(t::AbstractString) = ncodeunits(t) == 3 &&
    (codeunit(t, 1) | 0x20) == UInt8('x') && (codeunit(t, 2) | 0x20) == UInt8('m') &&
    (codeunit(t, 3) | 0x20) == UInt8('l')
_pi_content_spaced(c::AbstractString) =
    isempty(c) || XMLTokenizer.is_whitespace(codeunit(c, 1))
@noinline _reserved_pi_target(t::AbstractString) =
    error("not well-formed: the processing-instruction target \"", t,
          "\" is reserved (XML 1.0 §2.6)")
@noinline _unspaced_pi_target(t::AbstractString) =
    error("not well-formed: no white space after the processing-instruction target \"", t,
          "\" (XML 1.0 §2.6)")
# A processing instruction of the internal subset, `s[i:j-1]` between its `<?` and its `?>`,
# which the DTD reader steps over: its target ends at the first byte that no name holds, as
# the tokenizer ends it in the document, and is checked as one there.
function _check_subset_pi(s::AbstractString, i::Int, j::Int)
    k = i
    while k < j && XMLTokenizer.is_name_byte(codeunit(s, k))
        k += 1
    end
    target = SubString(s, i, prevind(s, k))
    _is_xml10_name(target) || _not_a_name("processing-instruction target", target)
    _is_reserved_pi_target(target) && _reserved_pi_target(target)
    _pi_content_spaced(SubString(s, k, prevind(s, j))) || _unspaced_pi_target(target)
    return nothing
end

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

# An overlong sequence encodes a character in more bytes than it needs, and is malformed UTF-8.
# Up to Julia 1.13, `UInt32` raises on it; from 1.14 it returns the code point. Read at load time
# from the conversion itself: where it raises, the test on each character below folds away.
function _overlong_decodes()
    try
        UInt32(first("\xc1\x81"))
        return true
    catch
        return false
    end
end
const _OVERLONG_DECODES = _overlong_decodes()

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
            _OVERLONG_DECODES && Base.isoverlong(c) && throw(Base.InvalidCharError(c))
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
# decimal form carrying a letter is rejected too, and so is the form `&#X`, which the decoder
# reads but the rule CharRef does not allow (XML 1.0 §4.1). A named reference that is not
# predefined is checked against what the DTD declares: `_apply_declarations` has already
# replaced every reference to an internal entity, so a name arriving here is external, unparsed,
# or has no declaration behind it (XML 1.0 §4.1, the "Entity Declared" well-formedness
# constraint), which is refused only when `names` holds. A `&` that starts neither form — one
# followed by no name, or by a name or a digit run without its `;` — is refused too: a literal
# `&` may only start a reference (XML 1.0 §2.4).
_check_refs_strict(s::AbstractString, names::Bool) = _check_refs(s, names, nothing, nothing, false)

# What the check knows of the DTD (`_strict_context`): whether "Entity Declared" binds, and the
# general entities declared external or unparsed, whose references the inclusion leaves as
# written. `in_attr` says the span is an attribute value. A document without DTD shares one
# value, `_NO_DTD`, so that the check costs it nothing beyond the flag.
struct _StrictContext
    names::Bool
    external::Union{Nothing, Set{String}}
    unparsed::Union{Nothing, Set{String}}
end
const _NO_DTD = _StrictContext(true, nothing, nothing)

_check_refs_strict(s::AbstractString, ctx::_StrictContext, in_attr::Bool) =
    _check_refs(s, ctx.names, ctx.external, ctx.unparsed, in_attr)

function _check_refs(s::AbstractString, names::Bool, external, unparsed, in_attr::Bool)
    cu = codeunits(s)
    n = length(cu)
    i = findnext(==(UInt8('&')), cu, 1)
    while i !== nothing
        if i + 1 <= n && @inbounds(cu[i + 1]) == UInt8('#')
            j, cp = _charref_at(cu, i, n)
            j > 0 || _no_reference(s, i)
            # `_charref_at` also reads `&#X`, which the levels below `:strict` decode; the rule
            # CharRef takes `&#x` only.
            @inbounds(cu[i + 2]) == UInt8('X') &&
                error("not well-formed: character reference \"", String(cu[i:j]),
                      "\" with an uppercase X (XML 1.0 §4.1)")
            _is_xml_char(cp) ||
                error("not well-formed: illegal character reference \"", String(cu[i:j]), "\"")
        else
            j = _name_end(cu, i + 1, n)
            j > 0 || _no_reference(s, i)
            if names || external !== nothing || unparsed !== nothing
                _, len = _predefined_at(cu, i, n)
                len == 0 && _check_named(s, cu, i, j, names, external, unparsed, in_attr)
            end
        end
        i = findnext(==(UInt8('&')), cu, j + 1)   # j + 1 ≤ n + 1, where findnext answers `nothing`
    end
end

# A literal `&` may only start a reference (XML 1.0 §2.4).
@noinline _no_reference(s::AbstractString, i::Int) =
    error("not well-formed: \"&\" that starts no reference: \"", first(SubString(s, i), 12),
          "\" (XML 1.0 §2.4)")

# A named reference that is not predefined. An unparsed entity is refused anywhere (WFC: Parsed
# Entity, §4.1), an external one in an attribute value (WFC: No External Entity References,
# §3.1) and left as written in content; any other name has no declaration behind it.
@noinline function _check_named(s::AbstractString, cu, i::Int, j::Int, names::Bool, external,
                                unparsed, in_attr::Bool)
    name = SubString(s, i + 1, prevind(s, j))
    if unparsed !== nothing && name in unparsed
        error("not well-formed: reference to unparsed entity \"", String(cu[i:j]),
              "\" (XML 1.0 §4.1)")
    elseif external !== nothing && name in external
        in_attr && error("not well-formed: reference to external entity \"", String(cu[i:j]),
                         "\" in an attribute value (XML 1.0 §3.1)")
    elseif names
        error("not well-formed: reference to undeclared entity \"", String(cu[i:j]),
              "\" (XML 1.0 §4.1)")
    end
    nothing
end

# Duplicate attributes (XML 1.0 §3.1, WFC: Unique Att Spec). Each new name is compared with
# the earlier names of its tag while they are fewer than `_SMALL_ATTRIBUTE_COUNT`. A tag of
# more attributes is checked once they are complete, by sorting its names: n attributes then
# cost O(n log n), whatever the names. A hash set would not guarantee that bound: Julia hashes
# strings with a fixed function, so the bound would rest on the names.
const _SMALL_ATTRIBUTE_COUNT = 32

# Throw on the name whose second occurrence comes first: the one that comparing each new name
# with the earlier ones would report.
function _check_unique_names(names::AbstractVector)
    keyed = [(names[i], i) for i in eachindex(names)]
    sort!(keyed)
    repeat_at = 0
    for k in 2:length(keyed)
        if keyed[k][1] == keyed[k - 1][1]
            i = keyed[k][2]
            (repeat_at == 0 || i < repeat_at) && (repeat_at = i)
        end
    end
    repeat_at == 0 || error("Duplicate attribute: $(names[repeat_at])")
    return nothing
end
_check_unique_names(attrs::Vector{<:Pair}, from::Int) =
    _check_unique_names([first(attrs[i]) for i in from:length(attrs)])

# Under `:strict`, each attribute of a tag comes after white space (XML 1.0 §3.1), which the
# tokenizer skips without requiring any.
@noinline _no_attr_space(name::AbstractString) =
    error("not well-formed: no white space before attribute \"", name, "\" (XML 1.0 §3.1)")

# The pseudo-attributes of the XML declaration, under `:strict` (XML 1.0 §2.8): `version`, then
# an optional `encoding`, then an optional `standalone`, each after white space. `before` is the
# byte before the name, and `prev` the name read before it, empty for the first. The values are
# read as written, since none of the three rules allows a reference.
function _check_decl_attr(before::UInt8, name::AbstractString, value::AbstractString,
                          prev::AbstractString)
    rank = _decl_rank(name)
    rank == 0 && _decl_error("2.8", "\"", name, "\" in the XML declaration; it takes only ",
                             "\"version\", \"encoding\" and \"standalone\"")
    isempty(prev) && rank != 1 && _no_version()
    rank <= _decl_rank(prev) &&
        _decl_error("2.8", "\"", name, "\" after \"", prev, "\" in the XML declaration")
    XMLTokenizer.is_whitespace(before) ||
        _decl_error("2.8", "no white space before \"", name, "\" in the XML declaration")
    if rank == 1
        _is_version_num(value) ||
            _decl_error("2.8", "version \"", value, "\" in the XML declaration; it must be \"1.\" ",
                        "then digits")
    elseif rank == 2
        _is_enc_name(value) ||
            _decl_error("4.3.3", "encoding name \"", value, "\" in the XML declaration; it must ",
                        "start with a letter, then letters, digits, \".\", \"_\" or \"-\"")
    else
        value == "yes" || value == "no" ||
            _decl_error("2.9", "standalone \"", value, "\" in the XML declaration; it must be ",
                        "\"yes\" or \"no\"")
    end
    return nothing
end

_decl_rank(name::AbstractString) =
    name == "version" ? 1 : name == "encoding" ? 2 : name == "standalone" ? 3 : 0

# An XML declaration with no pseudo-attribute, or whose first one is not `version`.
@noinline _no_version() = _decl_error("2.8", "XML declaration that does not start with \"version\"")

@noinline _decl_error(section::String, parts...) =
    error("not well-formed: ", parts..., " (XML 1.0 §", section, ")")

# VersionNum ::= '1.' [0-9]+ (XML 1.0 §2.8)
function _is_version_num(v::AbstractString)
    cu = codeunits(v)
    (length(cu) >= 3 && cu[1] == UInt8('1') && cu[2] == UInt8('.')) || return false
    return all(b -> UInt8('0') <= b <= UInt8('9'), @view cu[3:end])
end

# EncName ::= [A-Za-z] ([A-Za-z0-9._] | '-')* (XML 1.0 §4.3.3)
function _is_enc_name(v::AbstractString)
    letter(b) = (UInt8('A') <= b <= UInt8('Z')) || (UInt8('a') <= b <= UInt8('z'))
    cu = codeunits(v)
    (!isempty(cu) && letter(cu[1])) || return false
    return all(b -> letter(b) || UInt8('0') <= b <= UInt8('9') || b == UInt8('.') ||
                    b == UInt8('_') || b == UInt8('-'), @view cu[2:end])
end

# Token-stream → Node{S} builder. `convert_text` is `unescape` for parsed content (with entity
# decoding) and `identity` for zero-copy SubString parsing where the caller keeps raw escapes.
# `Val{W}` is the well-formedness level (:lenient / :structural / :strict); its checks compile
# away on :lenient.
function _parse(xml::String, ::Type{S}, convert_text::F, ::Val{W}) where {S, F, W}
    # `:strict` reads what the DTD declares before the parse, and refuses what it violates
    # (`_strict_context`); a document without DTD costs it nothing.
    strict = W === :strict ? _strict_context(xml) : _NO_DTD
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
    large_tag = false   # the tag being read has more than `_SMALL_ATTRIBUTE_COUNT` attributes

    for token in tokenize(xml)
        k = token.kind

        if k === TokenKinds.TEXT
            rawtext = raw(token, xml)
            W === :strict && _check_chars_strict(rawtext)
            W === :strict && token.has_entities && _check_refs_strict(rawtext, strict, false)
            v = _text_value(S, rawtext, token.has_entities, convert_text)
            push!(scratch_children, Node{S}(Text, nothing, nothing, v, nothing))

        elseif k === TokenKinds.OPEN_TAG
            nm = tag_name(token, xml)
            if W === :strict
                _is_xml10_name(nm) || _not_a_name("element name", nm)
            elseif W !== :lenient
                (isempty(nm) || !_is_name_start(first(nm))) &&
                    error("not well-formed: invalid element name \"$nm\"")
            end
            push!(tags, _to(S, nm))
            push!(attr_marks, length(scratch_attrs))
            push!(child_marks, length(scratch_children))

        elseif k === TokenKinds.SELF_CLOSE
            large_tag && (_check_unique_names(scratch_attrs, attr_marks[end] + 1); large_tag = false)
            t = pop!(tags)
            a = _take_slice!(scratch_attrs, pop!(attr_marks))
            pop!(child_marks)   # a self-closing element cannot have accumulated children
            push!(scratch_children, Node{S}(Element, t, a, nothing, nothing))

        elseif k === TokenKinds.TAG_CLOSE
            # The `>` of a start tag, or of an end tag; only a start tag can leave `large_tag` set.
            large_tag && (_check_unique_names(scratch_attrs, attr_marks[end] + 1); large_tag = false)

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
            W !== :lenient && _hasbyte(rawval, UInt8('<')) &&
                error("not well-formed: '<' in attribute value (XML 1.0 §3.1)")
            W === :strict && _check_chars_strict(rawval)
            W === :strict && token.has_entities && _check_refs_strict(rawval, strict, true)
            val = _text_value(S, _normalize_attr_ws(rawval), token.has_entities, convert_text)
            name = _to(S, pending_attr_name)
            if decl_attrs !== nothing
                if length(decl_attrs) < _SMALL_ATTRIBUTE_COUNT
                    any(p -> first(p) == name, decl_attrs) && error("Duplicate attribute: $name")
                else
                    large_tag = true   # checked at the end of the declaration
                end
                W === :strict && _check_decl_attr(codeunit(xml, pending_attr_name.offset),
                    pending_attr_name, rawval, isempty(decl_attrs) ? "" : first(decl_attrs[end]))
                push!(decl_attrs, name => val)
            elseif !isempty(attr_marks)
                from = attr_marks[end] + 1
                if length(scratch_attrs) - from + 1 < _SMALL_ATTRIBUTE_COUNT
                    for i in from:length(scratch_attrs)
                        first(scratch_attrs[i]) == name && error("Duplicate attribute: $name")
                    end
                else
                    large_tag = true   # checked once the tag closes
                end
                W === :strict && (XMLTokenizer.is_whitespace(codeunit(xml, pending_attr_name.offset)) ||
                                  _no_attr_space(pending_attr_name))
                W === :strict && (_is_xml10_name(pending_attr_name) ||
                                  _not_a_name("attribute name", pending_attr_name))
                push!(scratch_attrs, name => val)
            end

        elseif k === TokenKinds.XML_DECL_OPEN
            decl_attrs = Pair{S,S}[]

        elseif k === TokenKinds.XML_DECL_CLOSE
            large_tag && (_check_unique_names(decl_attrs, 1); large_tag = false)
            W !== :lenient && !isempty(child_marks) &&
                error("not well-formed: XML declaration inside element content")
            W === :strict && isempty(decl_attrs) && _no_version()
            a = isempty(decl_attrs) ? nothing : decl_attrs
            push!(scratch_children, Node{S}(Declaration, nothing, a, nothing, nothing))
            decl_attrs = nothing

        elseif k === TokenKinds.COMMENT_CONTENT
            cmt = raw(token, xml)
            W === :strict && _check_chars_strict(cmt)
            W === :strict && _has_double_hyphen(cmt) &&
                error("not well-formed: \"--\" within a comment")
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
            W === :strict && (_is_xml10_name(pending_pi_tag) ||
                              _not_a_name("processing-instruction target", pending_pi_tag))
            W === :strict && _is_reserved_pi_target(pending_pi_tag) &&
                _reserved_pi_target(pending_pi_tag)
            pending_pi_value = nothing

        elseif k === TokenKinds.PI_CONTENT
            text = raw(token, xml)
            W === :strict && (_pi_content_spaced(text) ||
                              _unspaced_pi_target(pending_pi_tag))
            content = lstrip(text)
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

