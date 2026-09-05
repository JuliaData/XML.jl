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

# The five names XML 1.0 §4.6 predefines, which need no declaration, and the characters they
# denote, index for index. `_predefined_at` below reads a name against them, for the decoder
# and for the `:strict` reference check alike; the entity reader tests membership directly.
const _PREDEFINED = ("amp", "lt", "gt", "apos", "quot")
const _PREDEFINED_CHARS = ('&', '<', '>', '\'', '"')

#------------------------------------------------------------------------------------# decode
# `unescape` is one pass over the bytes of its argument into a scratch buffer kept per task,
# then one `unsafe_string` copy of exactly the decoded bytes, so a value that carries a
# reference costs one allocation, the result itself. Every decision falls on an ASCII byte —
# `&`, `#`, `x`, a digit, a letter of the five names, `;` — which is a character boundary in
# UTF-8, so the runs between references are copied byte for byte. What is emitted is never
# re-read: a reference that resolves to `&` (`&#38;`) cannot start another one.

@inline function _hexdigit(b::UInt8)
    UInt8('0') <= b <= UInt8('9') && return b - UInt8('0')
    UInt8('a') <= b <= UInt8('f') && return b - UInt8('a') + 0x0a
    UInt8('A') <= b <= UInt8('F') && return b - UInt8('A') + 0x0a
    return 0xff
end

# The reference lexer, shared by the decoder below and by the `:strict` reference check in
# parse.jl. Each helper reads the bytes of one form from a `&` and reports where the form ends
# and what it denotes; what a caller does with a form it cannot resolve — keep the `&` as
# written, or reject the document — is the caller's. Every byte a helper decides on is ASCII,
# hence a character boundary in UTF-8.

# The character reference whose `&#` sits at `i`: `(j, cp)`, the index of its `;` and the code
# point its digit run denotes, or `j == 0` when the bytes form no reference. `x` or `X` selects
# the hexadecimal form. The run is read on the hexadecimal alphabet in both forms, and a run the
# form cannot parse — a letter in the decimal form, a value past U+10FFFF — comes back as
# `typemax(UInt32)`, outside every character range.
@inline function _charref_at(cu, i::Int, n::Int)
    j = i + 2
    j <= n || return (0, 0x00000000)
    @inbounds hex = cu[j] == UInt8('x') || cu[j] == UInt8('X')
    hex && (j += 1)
    start = j
    cp = 0x00000000
    bad = false
    while j <= n
        @inbounds d = _hexdigit(cu[j])
        d == 0xff && break
        bad |= !hex && d >= 0x0a
        if !bad
            cp = cp * (hex ? 0x10 : 0x0a) + d   # cp ≤ 0x10FFFF here, so no UInt32 overflow
            bad = cp > 0x10FFFF
        end
        j += 1
    end
    (j > start && j <= n && @inbounds(cu[j]) == UInt8(';')) || return (0, 0x00000000)
    return (j, bad ? typemax(UInt32) : cp)
end

# The named reference whose name would start at `a`: the index of its `;`, or 0 when the bytes
# form no reference. The name is read on the ASCII subset of the Name production (XML 1.0 §2.3).
@inline function _name_end(cu, a::Int, n::Int)
    (a <= n && _is_ascii_name_start(@inbounds(cu[a]))) || return 0
    j = a + 1
    while j <= n && _is_ascii_name_char(@inbounds(cu[j]))
        j += 1
    end
    return (j <= n && @inbounds(cu[j]) == UInt8(';')) ? j : 0
end
@inline _is_ascii_name_start(b::UInt8) =
    (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) || b == UInt8('_') || b == UInt8(':')
@inline _is_ascii_name_char(b::UInt8) =
    _is_ascii_name_start(b) || (UInt8('0') <= b <= UInt8('9')) || b == UInt8('.') || b == UInt8('-')

# The predefined reference at `i`, where `cu[i]` is `&`: `(cp, len)`, the character it denotes
# and its length in code units from the `&` to the `;`, or `len == 0` when the bytes spell none
# of the five names followed by `;`. The names are taken as byte tuples, so the recursion over
# them unrolls at compile time and each comparison reads an immediate.
const _PREDEFINED_BYTES = map(name -> Tuple(codeunits(name)), _PREDEFINED)
@inline _predefined_at(cu, i::Int, n::Int) = _predefined_at(cu, i, n, _PREDEFINED_BYTES, _PREDEFINED_CHARS)
@inline _predefined_at(cu, i::Int, n::Int, ::Tuple{}, ::Tuple{}) = (0x00000000, 0)
@inline function _predefined_at(cu, i::Int, n::Int, names::Tuple, chars::Tuple)
    name = first(names)
    len = length(name) + 2   # the `&`, the name, the `;`
    if i + len - 1 <= n && _spells(cu, i + 1, name) && @inbounds(cu[i + len - 1]) == UInt8(';')
        return (UInt32(first(chars)), len)
    end
    return _predefined_at(cu, i, n, Base.tail(names), Base.tail(chars))
end
@inline function _spells(cu, a::Int, name::NTuple{N, UInt8}) where {N}
    for k in 1:N
        @inbounds cu[a + k - 1] == name[k] || return false
    end
    return true
end

# Classify the bytes at `i`, where `cu[i]` is `&`: `(cp, len)`, the code point the reference
# denotes and its length in code units from the `&` to the `;`, or `len == 0` when the bytes
# form no reference the decoder resolves, so that the `&` is kept as written: a `&` that starts
# neither form, a name that is not one of the five, a numeric reference whose value
# `isvalid(Char, cp)` refuses — a surrogate, or past U+10FFFF, digits overflowing included.
@inline function _reference_at(cu, i::Int, n::Int)
    if i + 1 <= n && @inbounds(cu[i + 1]) == UInt8('#')
        j, cp = _charref_at(cu, i, n)
        j > 0 && isvalid(Char, cp) && return (cp, j - i + 1)
        return (0x00000000, 0)
    end
    return _predefined_at(cu, i, n)
end

# The scratch buffer lives in the task's local storage, so tasks never share it, and grows to
# the input's length, which bounds the output. Past `_SCRATCH_CAP` a fresh vector serves
# instead, so no task retains more than the cap; copying such a value dwarfs its allocation.
const _SCRATCH_CAP = 1 << 16
function _decode_scratch(n::Int)
    n > _SCRATCH_CAP && return Vector{UInt8}(undef, n)
    buf = get!(task_local_storage(), :xml_unescape_scratch) do
        Vector{UInt8}(undef, 256)
    end::Vector{UInt8}
    length(buf) < n && resize!(buf, n)
    return buf
end

# Decode `cu` into the scratch: `(buf, m, nrefs)`, the buffer, the decoded length and the
# number of references resolved. The writes are bounds-checked; a `Char` holds its UTF-8
# bytes in its `UInt32`, most significant first, so a reference is written from that word.
function _decode_to_scratch!(cu, n::Int)
    buf = _decode_scratch(n)
    i = 1
    k = 1
    nrefs = 0
    while i <= n
        @inbounds b = cu[i]
        if b == UInt8('&')
            cp, len = _reference_at(cu, i, n)
            if len != 0
                c = Char(cp)
                u = reinterpret(UInt32, c)
                for s in 1:ncodeunits(c)
                    buf[k] = (u >> (32 - 8s)) % UInt8
                    k += 1
                end
                nrefs += 1
                i += len
                continue
            end
        end
        buf[k] = b
        k += 1
        i += 1
    end
    return (buf, k - 1, nrefs)
end

# The result's allocation in `unsafe_string` is a point where a collection, and then the
# task's pending finalizers, can run: a finalizer that decoded a value of its own would reuse
# this task's scratch under the copy. Finalizers are held off across the copy, as Base does
# around its locks, and restored whatever happens. The copy is the path's one allocation,
# so the guard stays off the decode loop.
@inline function _take_string(buf::Vector{UInt8}, m::Int)
    GC.enable_finalizers(false)
    try
        return GC.@preserve buf unsafe_string(pointer(buf), m)
    finally
        GC.enable_finalizers(true)
    end
end

# Replace a numeric character reference with its Unicode character.
# Numeric character references encode characters by code point: decimal (&#233; → é) or hex (&#xE9; → é).
function _unescape_charref(ref::AbstractString)
    is_hex = length(ref) > 3 && ref[3] in ('x', 'X')
    digits = SubString(ref, is_hex ? 4 : 3, length(ref) - 1)
    cp = tryparse(UInt32, digits; base = is_hex ? 16 : 10)
    !isnothing(cp) && isvalid(Char, cp) ? string(Char(cp)) : ref
end

# Resolver for a regular-expression match, used by `_resolve_charrefs` in `entities.jl` on
# an entity's replacement text, once per declaration. `unescape` itself decodes through
# `_reference_at`, with the same outcomes.
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
exactly once (no double-unescaping); an `&` that starts no reference is kept as written.

A `SubString{String}` that carries no reference is returned unchanged with no allocation —
the common case for typical XML attribute and text content. A value that carries one costs
one allocation, the decoded string itself.
"""
function unescape(x::AbstractString)
    occursin('&', x) || return string(x)
    cu = codeunits(x)
    buf, m, nrefs = _decode_to_scratch!(cu, length(cu))
    return nrefs == 0 ? string(x) : _take_string(buf, m)
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

# XML 1.0 §2.11 end-of-line normalization: "the XML processor MUST behave as if it
# normalized all line breaks … on input, before parsing" — the literal pair CR LF becomes
# ONE LF, then each remaining literal #xD becomes LF, while character references (`&#13;`)
# are written with `&`, which no rewrite touches, so they reach entity resolution intact.
#
# How that is honoured depends on how the document is held, and the two ways are chosen by
# DISPATCH rather than by a runtime test, which is what keeps the common path's accessor
# bodies byte-identical:
#
#   - a `String`-backed document is rewritten here, once, at the entry (next to the BOM
#     handling). A CR-free one — the entire LF world — comes back unchanged after a single
#     memchr-backed scan; a CR-carrying one is rewritten, and every downstream span, token
#     and zero-copy view then lives in the normalized document;
#   - a document held as any other string type — a `StringView` over a memory-mapped file
#     being the case the README documents — would have to be copied into the heap to be
#     rewritten here, which is the one thing the mapping exists to avoid. It is left alone,
#     and each value is normalized on the way out instead (`_read_eol` below).
#
# Collapsing the two into one accessor that tests at runtime which normalization a
# value needs is not an option: any extra live branch or inlined scan in the
# union-returning accessors overflows the caller-side union-split of their merge φ and
# heap-boxes the clean-path return, 32 B per value (#105/#113 class). A branch resolved
# by dispatch costs the clean path nothing.
_normalize_input_eol(s::String) = occursin('\r', s) ? _rewrite_content_eol(s) : s
_normalize_input_eol(s::SubString{String}) = occursin('\r', s) ? _rewrite_content_eol(s) : s
_normalize_input_eol(s::AbstractString) = s

# §2.11 for a document that was NOT rewritten at the entry: normalize one value's own bytes
# as it is reported. Applied to the RAW span, before entity resolution, so that a `&#13;`
# still yields a real CR — the spec normalizes line breaks first, and references resolve
# after. For a `String`-backed document the span is a `SubString{String}` and this is the
# identity: it inlines away, adds no live branch, and leaves the caller's merge φ untouched.
@inline _read_eol(s::SubString{String}) = s
_read_eol(s::AbstractString) = occursin('\r', s) ? _rewrite_content_eol(s) : s

# After the CR LF → LF rewrite, a byte position shifts left by the number of CR LF pairs
# strictly before it (a lone CR rewrites in place). For translating caller-supplied
# start offsets (`Cursor(data, startpos)`) when the document needed rewriting.
#
# That constructor is its only caller and is deprecated for removal in v0.5, so this goes
# with it — no other entry takes a source offset from the caller.
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

# The rewritten value is never longer than its source — a CR LF pair loses a byte, a lone CR
# keeps its own — so the buffer is allocated once at that bound and shrunk to what was
# written. Knowing the bound is what makes a growable stream unnecessary on a path that runs
# once per value carrying a line end. `StringVector` allocates in the layout `String` wraps
# without a copy; a plain `Vector{UInt8}` is copied again on conversion. 96 B per call for a
# ten-byte value.
function _rewrite_content_eol(s::AbstractString)
    cu = codeunits(s)
    n = length(cu)
    out = Base.StringVector(n)
    i = 1
    j = 1
    @inbounds while j <= n
        b = cu[j]
        if b == 0x0D
            out[i] = 0x0A
            j < n && cu[j + 1] == 0x0A && (j += 1)
        else
            out[i] = b
        end
        i += 1
        j += 1
    end
    i == n + 1 || resize!(out, i - 1)
    String(out)
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

# Both branches return the argument's own type: every reader's decode funnel calls this on
# its hot path, and a `Union{SubString{String}, String}` return would heap-box the dominant
# clean-path SubString at every non-inlined call site — one 32-byte box per read (#98, #105).
function unescape(x::SubString{String})
    occursin('&', x) || return x
    cu = codeunits(x)
    buf, m, nrefs = _decode_to_scratch!(cu, length(cu))
    return nrefs == 0 ? x : SubString(_take_string(buf, m))
end
