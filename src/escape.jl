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
    unescape(x::SubString{String}) -> Union{SubString{String}, String}

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
# (no allocation) — the dominant case.
function _normalize_attr_ws(s::AbstractString)
    cu = codeunits(s)
    dirty = false
    @inbounds for b in cu
        if b == 0x09 || b == 0x0A || b == 0x0D
            dirty = true
            break
        end
    end
    dirty || return s
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

function unescape(x::SubString{String})
    occursin('&', x) || return x
    replace(String(x), _ENTITY_RE => _unescape_entity)
end

