#-----------------------------------------------------------------------------# sourceview
"""
    XML.sourceview(s::Union{String, SubString{String}}) -> AbstractString

Return `s` as a source that `Cursor` and `parse(·, LazyNode)` read where it lies, without the copy
they make of a `String` that holds a carriage return.

A `String` source has its line ends normalized once, at the entry (XML 1.0 §2.11), which copies
the whole document when it holds a CR. The source returned here is normalized value by value
instead, as it is read:

- the values are those the `String` gives, with line ends, attribute values and references
  normalized;
- `sourcetext` and `sourcespan` refer to the bytes of `s`, carriage returns included;
- nothing is copied, unless the declarations of the DOCTYPE change the document, which is then
  read from a rewritten copy, to which `sourcetext` and `sourcespan` refer.

This suits a scan that reads few values, such as finding one element in a large document. A full
read costs more than through the `String`, since each value is normalized as it is read. `Node`
and `FlatNode` copy their source into a `String` before they parse it, so `sourceview` gains them
nothing.

The result views the bytes of `s`: a `StringView` of Base from Julia 1.14, a type internal to
XML.jl before, and a `SubString` of it for a `SubString{String}`. The readers keep that type:
`tag`, `sourcetext`, and a `value` with nothing to normalize return a `SubString` of it, where
the `String` gives a `SubString{String}`. A value that was normalized is a `String`, and the
attribute pairs are `SubString{String}`, as from any source. Code that needs a `String` converts
with `String(v)`.

```julia
cursor = Cursor(XML.sourceview(xml))     # no copy, whatever the line ends of `xml`
```
"""
function sourceview end

sourceview(s::SubString{String}) = SubString(sourceview(parent(s)), s.offset + 1, s.offset + lastindex(s))

if isdefined(Base, :StringView)
    sourceview(s::String) = Base.StringView(codeunits(s))

    # A rewritten document comes back as the type it was given (see `_rebuild_source`).
    const _CodeUnitsView = Base.StringView{Base.CodeUnits{UInt8, String}}
    _rebuild_source(::_CodeUnitsView, bytes::Vector{UInt8}) = Base.StringView(codeunits(String(bytes)))
    _rebuild_source(::SubString{_CodeUnitsView}, bytes::Vector{UInt8}) =
        SubString(Base.StringView(codeunits(String(bytes))))
else
    # Before Julia 1.14, a type of XML.jl's own wraps the `String`. Besides what an `AbstractString`
    # needs, it passes to the `String` the operations a reader repeats: the search for a
    # character, the search for a byte, the comparison and the output. The `String` searches a
    # character with `memchr`, where the generic search decodes every character.
    struct SourceView <: AbstractString
        s::String
    end
    const _SourceViews = Union{SourceView, SubString{SourceView}}

    sourceview(s::String) = SourceView(s)

    Base.ncodeunits(w::SourceView) = ncodeunits(w.s)
    Base.codeunit(::SourceView) = UInt8
    Base.@propagate_inbounds Base.codeunit(w::SourceView, i::Integer) = codeunit(w.s, i)
    Base.codeunits(w::SourceView) = codeunits(w.s)
    Base.iterate(w::SourceView, i::Integer = 1) = iterate(w.s, i)
    Base.isvalid(w::SourceView, i::Integer) = isvalid(w.s, i)
    Base.thisind(w::SourceView, i::Int) = thisind(w.s, i)
    Base.String(w::SourceView) = w.s

    # The `String`, or the `SubString{String}`, that a source views, with the same indices.
    _viewed(w::SourceView) = w.s
    _viewed(x::SubString{SourceView}) =
        SubString(x.string.s, x.offset + 1, thisind(x.string.s, x.offset + x.ncodeunits))

    const _CharEquals = Base.Fix2{<:Union{typeof(isequal), typeof(==)}, <:AbstractChar}
    Base.findnext(p::_CharEquals, x::_SourceViews, i::Integer) = findnext(p, _viewed(x), i)
    Base.findprev(p::_CharEquals, x::_SourceViews, i::Integer) = findprev(p, _viewed(x), i)

    @inline XMLTokenizer._findbyte(w::SourceView, b::UInt8, i::Int) = XMLTokenizer._findbyte(w.s, b, i)
    @inline XMLTokenizer._findbyte(x::SubString{SourceView}, b::UInt8, i::Int) = XMLTokenizer._findbyte_bytes(
        view(codeunits(x.string.s), x.offset+1:x.offset+ncodeunits(x)), b, i)

    Base.:(==)(a::_SourceViews, b::_SourceViews) = _viewed(a) == _viewed(b)
    Base.:(==)(a::_SourceViews, b::Union{String, SubString{String}}) = _viewed(a) == b
    Base.:(==)(a::Union{String, SubString{String}}, b::_SourceViews) = a == _viewed(b)
    Base.hash(x::_SourceViews, h::UInt) = hash(_viewed(x), h)
    Base.write(io::IO, x::_SourceViews) = Base.write(io, _viewed(x))
    Base.print(io::IO, x::_SourceViews) = (Base.write(io, x); nothing)

    _rebuild_source(::SourceView, bytes::Vector{UInt8}) = SourceView(String(bytes))
    _rebuild_source(::SubString{SourceView}, bytes::Vector{UInt8}) = SubString(SourceView(String(bytes)))
end
