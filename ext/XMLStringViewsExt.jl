module XMLStringViewsExt

# `Cursor` and `LazyNode` keep whatever string type the document arrives as, so a document read
# through a `StringView` over `Mmap` — the recipe the README gives for files too large for the
# heap — needs the expanded bytes returned as a `StringView` too. `Mmap.mmap` returns an
# ordinary `Vector{UInt8}`, so a mapping and a heap vector are the same concrete type and the
# substitution stays invisible to inference: the reader's type parameter is what it would have
# been for a document that declares nothing.

using XML: XML
using StringViews: StringView

# Both methods return exactly the concrete type of their argument, which is what keeps the
# entry type-stable. A `StringView` over anything but a `Vector{UInt8}` gets no method: rebuilt
# from bytes it would come back as a different type, and the fallback declines instead, leaving
# such a document's references literal. The `SubString` form is what `_drop_bom` produces when a
# mapped document opens with an encoding signature.
XML._rebuild_source(::StringView{Vector{UInt8}}, bytes::Vector{UInt8}) = StringView(bytes)
XML._rebuild_source(::SubString{StringView{Vector{UInt8}}}, bytes::Vector{UInt8}) =
    SubString(StringView(bytes))

end
