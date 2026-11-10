module ByteSearch

# The byte searches of the tokenizer and of the readers: where a byte next occurs in a
# string, whether a span holds one, and whether a comment holds `--`. Each has a method for
# any string type, and methods for the types whose bytes it can read as an array. The
# methods that only Julia 1.10 needs stand together, at the end.

# The index of the first byte `b` at or after `i`, or `nothing`; `b` is ASCII, so it never falls
# inside a multi-byte character. A `String` is searched through its bytes, with `memchr` past a
# short stretch. So is a `SubString{String}`, through its parent's bytes, since its own search
# for a character decodes every character under Julia 1.10. Any other string type is read byte
# by byte. On such a type, a search for a character decodes every character, and a byte search
# on the code units copies them all under Julia 1.13, which takes them for a dense array. A
# `StringView` is searched through its bytes, as a `String`: by the method below from Julia
# 1.14, where Base defines the type, and by the StringViews extension before.
@inline function _findbyte(data::AbstractString, b::UInt8, i::Int)
    n = ncodeunits(data)
    @inbounds while i <= n
        codeunit(data, i) == b && return i
        i += 1
    end
    return nothing
end
@inline _findbyte(s::String, b::UInt8, i::Int) = _findbyte_bytes(codeunits(s), b, i)
@inline _findbyte(s::SubString{String}, b::UInt8, i::Int) =
    _findbyte_bytes(view(codeunits(parent(s)), s.offset+1:s.offset+ncodeunits(s)), b, i)
if isdefined(Base, :StringView)
    @inline _findbyte(s::Union{Base.StringView, SubString{<:Base.StringView}}, b::UInt8, i::Int) =
        _findbyte_bytes(codeunits(s), b, i)
end

# The search through bytes that `memchr` can scan. The first sixteen are read one at a time:
# between dense tags the byte is mostly found within them, where the call to `memchr` costs
# more than the loop. `memchr` takes the rest. It searches bytes, not characters, since the
# stretch read one at a time may end inside a multi-byte character.
@inline function _findbyte_bytes(bytes::AbstractVector{UInt8}, b::UInt8, i::Int)
    n = length(bytes)
    stop = min(n, i + 15)
    @inbounds while i <= stop
        bytes[i] == b && return i
        i += 1
    end
    return findnext(==(b), bytes, i)
end

# The index at or after `i` of the byte `b` in `cu`, the code units of `s`, or `nothing`.
# Code units that are an array of bytes, as those of a `StringView`, or that belong to a
# `String` or a `SubString{String}`, are searched with `memchr`. Those of another string
# type claim to be a dense array too, and Julia 1.13 copies them all on each such search:
# `_findbyte` reads that type byte by byte instead.
const _StringCodeUnits = Base.CodeUnits{UInt8, <:Union{String, SubString{String}}}
@inline _findbyte_cu(s::AbstractString, cu, b::UInt8, i::Int) = findnext(==(b), cu, i)
@inline _findbyte_cu(s::AbstractString, cu::Base.CodeUnits{UInt8}, b::UInt8, i::Int) =
    _findbyte(s, b, i)
@inline _findbyte_cu(s::AbstractString, cu::_StringCodeUnits, b::UInt8, i::Int) =
    findnext(==(b), cu, i)

# Whether the byte `b` occurs in the whole of `s`, or in the bytes [start, stop) of `data`.
# `b` is ASCII, so it never falls inside a multi-byte character. This search is for a byte
# that is mostly absent, as the `&` of a text: it reads every byte, so it has no use for
# the stretch that `_findbyte` reads one byte at a time. For any string type, the bytes
# [start, stop) are searched as a view of `data`: the tokenizer builds such views, and
# defines that method.
@inline _hasbyte(s::AbstractString, b::UInt8) = occursin(Char(b), s)

# The index of the first byte `b` at or after `i`, or `nothing`, by the string's own search
# for a character: the `<` that ends a text, the quote that closes an attribute value, the
# `&` that opens a reference.
@inline _findchar(data::AbstractString, b::UInt8, i::Int) = findnext(Char(b), data, i)

# Whether the text of a comment holds `--`, which XML 1.0 §2.5 does not allow there.
# `:strict` only.
_has_double_hyphen(s::AbstractString) = occursin("--", s)

# Under Julia 1.10, Base searches a `String` for a character through its bytes, with
# `memchr`, but a `SubString{String}` one character at a time, each of them decoded. It
# searches a `SubString{String}` for a string such as `--` the same way. There, a span of a
# `String` is searched through the bytes of that `String`, and a `SubString{String}` through
# those of its parent. In a comment, each `-` is found through the bytes, and the byte after
# it is read.
if VERSION < v"1.11"
    @inline _hasbyte(data::String, b::UInt8, start::Int, stop::Int) =
        findnext(==(b), view(codeunits(data), start:stop-1), 1) !== nothing
    @inline _hasbyte(data::SubString{String}, b::UInt8, start::Int, stop::Int) =
        _hasbyte(data.string, b, data.offset + start, data.offset + stop)
    @inline _hasbyte(s::SubString{String}, b::UInt8) =
        _hasbyte(s.string, b, s.offset + 1, s.offset + ncodeunits(s) + 1)
    @inline _findchar(data::SubString{String}, b::UInt8, i::Int) = _findbyte(data, b, i)
    function _has_double_hyphen(s::SubString{String})
        n = ncodeunits(s)
        i = 1
        while (j = _findbyte(s, UInt8('-'), i)) !== nothing
            j < n && codeunit(s, j + 1) == UInt8('-') && return true
            i = j + 1
        end
        return false
    end
end

end # module ByteSearch
