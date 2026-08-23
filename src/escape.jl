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
    unescape(x::SubString{String}) -> SubString{String}

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

# XML 1.0 §3.3.3 attribute-value normalization, applied to the RAW value slice BEFORE
# entity resolution: the literal pair CR LF becomes ONE space, then each remaining literal
# #x9 / #xA / #xD becomes a space. Character references (`&#10;` …) are untouched here and
# resolve afterwards — which is exactly why this pass must run before `unescape`. All the
# targets are ASCII, so the byte loop is multi-byte-safe. Clean values return unchanged
# — the dominant case — and each method returns its input type concretely: a union-typed
# return would heap-box the clean-path SubString at every call site, one 32-byte box per
# attribute in every reader's hot path (#98).
_normalize_attr_ws(s::AbstractString) = _attr_ws_dirty(s) ? _rewrite_attr_ws(s) : s
_normalize_attr_ws(s::SubString{String}) =
    _attr_ws_dirty(s) ? SubString(_rewrite_attr_ws(s)) : s

function _attr_ws_dirty(s::AbstractString)
    @inbounds for b in codeunits(s)
        (b == 0x09 || b == 0x0A || b == 0x0D) && return true
    end
    false
end

function _rewrite_attr_ws(s::AbstractString)
    cu = codeunits(s)
    io = IOBuffer(sizehint = ncodeunits(s))
    n = length(cu)
    j = 1
    @inbounds while j <= n
        b = cu[j]
        if b == 0x0D
            Base.write(io, 0x20)
            j < n && cu[j + 1] == 0x0A && (j += 1)
        elseif b == 0x0A || b == 0x09
            Base.write(io, 0x20)
        else
            Base.write(io, b)
        end
        j += 1
    end
    String(take!(io))
end

# XML 1.0 §2.11 end-of-line normalization, applied ON INPUT at every reader's document
# entry point (next to the BOM handling), exactly as the spec words it: "the XML processor
# MUST behave as if it normalized all line breaks … on input, before parsing". The literal
# pair CR LF becomes ONE LF, then each remaining literal #xD becomes LF; character
# references (`&#13;`) are written with `&`, which the rewrite never touches, so they
# survive to entity resolution. A CR-free document — the entire LF world — is returned
# unchanged after one memchr-backed scan; a CR-carrying document is rewritten ONCE, and
# every downstream span, token and zero-copy view then lives in the normalized document.
# Normalizing per VALUE instead was measured to heap-box the union-returning value
# accessors' clean-path return (32 B per value: any extra live branch or inlined scan in
# those bodies overflows the caller-side union-split of their merge φ — #105/#113 class).
_normalize_input_eol(s::AbstractString) = occursin('\r', s) ? _rewrite_content_eol(s) : s

# After the CR LF → LF rewrite, a byte position shifts left by the number of CR LF pairs
# strictly before it (a lone CR rewrites in place). For translating caller-supplied
# start offsets (`Cursor(data, startpos)`) when the document needed rewriting.
function _translate_eol_pos(s::AbstractString, pos::Int)
    cu = codeunits(s)
    n = min(pos - 1, length(cu))
    shift = 0
    j = 1
    @inbounds while j < n
        if cu[j] == 0x0D && cu[j + 1] == 0x0A
            shift += 1
            j += 2
        else
            j += 1
        end
    end
    pos - shift
end

function _rewrite_content_eol(s::AbstractString)
    cu = codeunits(s)
    io = IOBuffer(sizehint = ncodeunits(s))
    n = length(cu)
    j = 1
    @inbounds while j <= n
        b = cu[j]
        if b == 0x0D
            Base.write(io, 0x0A)
            j < n && cu[j + 1] == 0x0A && (j += 1)
        else
            Base.write(io, b)
        end
        j += 1
    end
    String(take!(io))
end

# An attribute name or value as the `SubString{String}` that the materialized `Attributes`
# dict and `eachattribute`'s element type are built from. When the document is a `String`
# the token view already is one and this is the identity; any other source — a `StringView`
# over a memory-mapped file, say — has its bytes copied here, and only its own. The generic
# routes (`convert`, `String(::AbstractString)`, `collect(codeunits(…))`, `copyto!`) walk the
# whole document once per attribute instead, which is quadratic in document size (#134).
@inline _as_substring(s::SubString{String}) = s
@inline _as_substring(s::String) = SubString(s)
function _as_substring(s::AbstractString)
    cu = codeunits(s)
    n = length(cu)
    bytes = Vector{UInt8}(undef, n)
    @inbounds for i in 1:n
        bytes[i] = cu[i]
    end
    SubString(String(bytes))
end

# The rewrite result is wrapped back into `SubString` so both paths return the same
# concrete type: every reader's decode funnel calls this on its hot path, and a
# `Union{SubString{String}, String}` return would heap-box the dominant clean-path
# SubString at every non-inlined call site — one 32-byte box per read (#98, #105).
function unescape(x::SubString{String})
    occursin('&', x) || return x
    SubString(replace(String(x), _ENTITY_RE => _unescape_entity))
end

