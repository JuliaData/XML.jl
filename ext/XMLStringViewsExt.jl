module XMLStringViewsExt

# `Cursor` and `LazyNode` keep whatever string type the document arrives as, so a document read
# through a `StringView` over `Mmap` — the recipe the README gives for files too large for the
# heap — needs the rewritten bytes returned as a `StringView` too. `Mmap.mmap` returns an
# ordinary `Vector{UInt8}`, so a mapping and a heap vector are the same concrete type and the
# substitution stays invisible to inference: the reader's type parameter is what it would have
# been for a document that declares nothing.

using XML: XML
using StringViews: StringView

# Each method returns exactly the concrete type of its argument, which is what keeps the entry
# type-stable. A `StringView` over a view of a whole `Vector{UInt8}` is rebuilt the same way,
# since `view(bytes, 1:length(bytes))` has the type of every such view. A `StringView` over
# anything else gets no method: rebuilt from bytes it would come back as a different type, and
# the entry refuses it instead, when its document needs the rewrite. The `SubString` forms are
# what `_drop_bom` produces when such a document opens with an encoding signature.
const _ByteView = SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int}}, true}

XML._rebuild_source(::StringView{Vector{UInt8}}, bytes::Vector{UInt8}) = StringView(bytes)
XML._rebuild_source(::SubString{StringView{Vector{UInt8}}}, bytes::Vector{UInt8}) =
    SubString(StringView(bytes))
XML._rebuild_source(::StringView{_ByteView}, bytes::Vector{UInt8}) =
    StringView(view(bytes, 1:length(bytes)))
XML._rebuild_source(::SubString{StringView{_ByteView}}, bytes::Vector{UInt8}) =
    SubString(StringView(view(bytes, 1:length(bytes))))

end
