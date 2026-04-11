#-----------------------------------------------------------------------------# RawType
"""
    RawType:
    - RawText                   # text
    - RawComment                # <!-- ... -->
    - RawCData                  # <![CDATA[...]]>
    - RawDeclaration            # <?xml attributes... ?>
    - RawProcessingInstruction  # <?NAME attributes... ?>
    - RawDTD                    # <!DOCTYPE ...>
    - RawElementOpen            # <NAME attributes... >
    - RawElementClose           # </NAME>
    - RawElementSelfClosed      # <NAME attributes... />
    - RawDocument               # Something to initialize with (not really used)
"""
@enum(RawType, RawDocument, RawText, RawComment, RawCData, RawProcessingInstruction,
    RawDeclaration, RawDTD, RawElementOpen, RawElementClose, RawElementSelfClosed)

@inline nodetype(x::RawType) =
    x === RawElementOpen ? Element :
    x === RawElementClose ? Element :
    x === RawElementSelfClosed ? Element :
    x === RawText ? Text :
    x === RawComment ? Comment :
    x === RawCData ? CData :
    x === RawDeclaration ? Declaration :
    x === RawDTD ? DTD :
    x === RawProcessingInstruction ? ProcessingInstruction :
    x === RawDocument ? Document :
    nothing

#-----------------------------------------------------------------------------# Raw
"""
    Raw(filename::String)

Create an iterator over raw chunks of data in an XML file.  Each chunk of data represents one of:

    - RawDocument                # Only used to initialize the iterator state.
    - RawText                    # text
    - RawComment                 # <!-- ... -->
    - RawCData                   # <![CDATA[...]]>
    - RawDeclaration             # <?xml attributes... ?>
    - RawProcessingInstruction   # <?NAME attributes... ?>
    - RawDTD                     # <!DOCTYPE ...>
    - RawElementOpen             # <NAME attributes... >
    - RawElementClose            # </NAME>
    - RawElementSelfClosed       # <NAME attributes... />

Useful functions:

    - view(o::Raw) --> view of the Vector{UInt8} chunk.
    - String(o::Raw) --> String of the chunk.
    - next(o::Raw) --> Raw of the next chunk (or `nothing`).
    - prev(o::Raw) --> Raw of the previous chunk (or `nothing`).
    - tag(o::Raw) --> String of the tag name (or `nothing`).
    - attributes(o::Raw) --> OrderedDict{String, String} of the attributes (or `nothing`).
    - value(o::Raw) --> String of the value (or `nothing`).
    - children(o::Raw) --> Vector{Raw} of the children (or `nothing`).
    - parent(o::Raw) --> Raw of the parent (or `nothing`)
    - depth(o::Raw) --> Int of the depth of the node in the XML DOM.
"""
struct Raw
    type::RawType
    depth::Int
    pos::Int
    len::Int
    data::Vector{UInt8}
    ctx::Vector{Bool} # Context for xml:space (Vector to support inheritance of context)
    has_xml_space::Bool # Whether data contains `xml:space` attribute at least once
end
function Raw(data::Vector{UInt8})#, ctx::Vector{Bool}=Bool[false])
    needle = Vector{UInt8}("xml:space")
    has_xml_space = findfirst(needle, data) !== nothing
    return Raw(RawDocument, 0, 0, 0, data, [false], has_xml_space)
end
function Raw(data::Vector{UInt8}, has_xml_space::Bool, ctx::Vector{Bool}=Bool[false])
    return Raw(RawDocument, 0, 0, 0, data, ctx, has_xml_space)
end

const _RAW_INDEX = WeakKeyDict{Vector{UInt8}, Any}()

struct _TokRec
    type::RawType
    depth::Int
    pos::Int
    len::Int
    ctx::Vector{Bool}
end

mutable struct _Index
    recs::Vector{_TokRec}
    last_raw::Raw
    built_end::Int
end

Base.read(filename::String, ::Type{Raw}) = isfile(filename) ?
                                           Raw(Mmap.mmap(filename)) :
                                           error("File \"$filename\" does not exist.")

Base.read(io::IO, ::Type{Raw}) = Raw(read(io))

Base.parse(x::AbstractString, ::Type{Raw}) = Raw(Vector{UInt8}(x))

# Mostly for debugging
Base.peek(o::Raw, n::Int) = String(view(o.data[o.pos+o.len+1:min(end, o.pos + o.len + n + 1)]))

function Base.show(io::IO, o::Raw)
    print(io, o.type, ':', o.depth, " (pos=", o.pos, ", len=", o.len, ")")
    o.len > 0 && printstyled(io, ": ", String(o); color=:light_green)
end
function Base.:(==)(a::Raw, b::Raw)
    a.type == b.type && a.depth == b.depth && a.pos == b.pos && a.len == b.len && a.data === b.data && a.ctx == b.ctx && a.has_xml_space == b.has_xml_space
end

Base.view(o::Raw) = view(o.data, o.pos:o.pos+o.len)
Base.String(o::Raw) = String(view(o))

Base.IteratorSize(::Type{Raw}) = Base.SizeUnknown()
Base.eltype(::Type{Raw}) = Raw

function Base.iterate(o::Raw, state=o)
    n = next(state)
    return isnothing(n) ? nothing : (n, n)
end

is_node(o::Raw) = o.type !== RawElementClose
xml_nodes(o::Raw) = Iterators.Filter(is_node, o)

#-----------------------------------------------------------------------------# get_name
is_name_start_char(x::UInt8) = x in UInt8('A'):UInt8('Z') || x in UInt8('a'):UInt8('z') || x == UInt8('_')
is_name_char(x::UInt8) = is_name_start_char(x) || x in UInt8('0'):UInt8('9') || x == UInt8('-') || x == UInt8('.') || x == UInt8(':')

name_start(data, i) = findnext(is_name_start_char, data, i)
name_stop(data, i) = findnext(!is_name_char, data, i) - 1

function get_name(data, i)
    i = name_start(data, i)
    j = name_stop(data, i)
    @views String(data[i:j]), j + 1
end

#-----------------------------------------------------------------------------# get_attributes
# starting at position i, return attributes up until the next '>' or '?' (DTD)
function get_attributes(data, i, j)
    i = name_start(data, i)
    (isnothing(j) || isnothing(i) || i > j) && return nothing
    out = OrderedDict{String,String}()
    while !isnothing(i) && i < j
        key, i = get_name(data, i)
        # get quotechar the value is wrapped in (either ' or ")
        i = findnext(x -> x === UInt8('"') || x === UInt8('''), data, i + 1)
        quotechar = data[i]
        i2 = findnext(==(quotechar), data, i + 1)
        @views value = String(data[i+1:i2-1])
        out[key] = value
        i = name_start(data, i2)
    end
    return out
end

# ----------------------------------------------------------------------------# Utilities supporting prev
function _get_or_init_index(o::Raw)
    idx = get(_RAW_INDEX, o.data, nothing)
    if idx === nothing
        start = Raw(o.data)  # fresh RawDocument
        _RAW_INDEX[o.data] = _Index(_TokRec[], start, 0)
        idx = _RAW_INDEX[o.data]
    end
    return idx
end
function _ensure_index_upto!(o::Raw, target_pos::Int)
    idx = _get_or_init_index(o)
    r = idx.last_raw
    while true
        n = next(r)
        if n === nothing
            idx.built_end = typemax(Int)
            idx.last_raw = r
            return idx
        end
        push!(idx.recs, _TokRec(n.type, n.depth, n.pos, n.len, copy(n.ctx)))
        endpos = n.pos + n.len
        idx.built_end = endpos
        idx.last_raw = n
        r = n
        if endpos >= target_pos
            return idx
        end
    end
end
function _find_prev_token(recs::Vector{_TokRec}, p::Int)
    lo, hi = 1, length(recs)
    ans = 0
    while lo <= hi
        mid = (lo + hi) >>> 1
        endpos = recs[mid].pos + recs[mid].len
        if endpos < p + 1
            ans = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return ans == 0 ? nothing : recs[ans]
end

#-----------------------------------------------------------------------------# update xml:space context
# check attributes for xml:space and update ctx if necessary
function get_ctx(o)
    att = attributes(o)
    if !isnothing(att) && haskey(att, "xml:space")
        if att["xml:space"] == "preserve"
            return true
        elseif att["xml:space"] == "default"
            return false
        else
            error("Invalid value for xml:space attribute: $(att["xml:space"]).  Must be 'preserve' or 'default'.")
        end
    end
    return nothing
end
function update_ctx!(ctx, o)
    new_ctx = get_ctx(o)
    if new_ctx !== nothing
        ctx[end] = new_ctx
    end
    return nothing
end

#-----------------------------------------------------------------------------# interface
"""
    nodetype(node) --> XML.NodeType

Return the `XML.NodeType` of the node.
"""
nodetype(o::Raw) = nodetype(o.type)

"""
    tag(node) --> String or Nothing

Return the tag name of `Element` and `PROCESSING_INSTRUCTION` nodes.
"""
function tag(o::Raw)
    o.type ∉ [RawElementOpen, RawElementClose, RawElementSelfClosed, RawProcessingInstruction] && return nothing
    return get_name(o.data, o.pos + 1)[1]
end

"""
    attributes(node) --> OrderedDict{String, String} or Nothing

Return the attributes of `Element`, `Declaration`, or `ProcessingInstruction` nodes.
"""
function attributes(o::Raw)
    if o.type === RawElementOpen || o.type === RawElementSelfClosed || o.type === RawProcessingInstruction
        i = o.pos
        i = name_start(o.data, i)
        i = name_stop(o.data, i)
        get_attributes(o.data, i + 1, o.pos + o.len)
    elseif o.type === RawDeclaration
        get_attributes(o.data, o.pos + 6, o.pos + o.len)
    else
        nothing
    end
end

"""
    value(node) --> String or Nothing

Return the value of `Text`, `CData`, `Comment`, or `DTD` nodes.
"""
function value(o::Raw)
    if o.type === RawText
        String(o)
    elseif o.type === RawCData
        String(view(o.data, o.pos+length("<![CDATA["):o.pos+o.len-3))
    elseif o.type === RawComment
        String(view(o.data, o.pos+length("<!--"):o.pos+o.len-3))
    elseif o.type === RawDTD
        String(view(o.data, o.pos+length("<!DOCTYPE "):o.pos+o.len-1))
    else
        nothing
    end
end

"""
    children(node) --> Vector{typeof(node)}

Return the children the node.  Will only be nonempty for `Element` and `Document` nodes.
"""
function children(o::Raw)
    if o.type === RawElementOpen || o.type === RawDocument
        depth = o.depth
        out = Raw[]
        for item in xml_nodes(o)
            if item.depth == depth + 1
                push!(out, item)
            end
            item.depth == depth && break
            o.type === RawDocument && item.depth == 2 && break # break if we've seen the doc root
        end
        out
    else
        Raw[]
    end
end

"""
    depth(node) --> Int

Return the depth of the node.  Will be `0` for `Document` nodes.  Not defined for `XML.Node`.
"""
function depth(o::Raw)
    o.depth
end

"""
    parent(node) --> typeof(node), Nothing

Return the parent of the node.  Will be `nothing` for `Document` nodes.  Not defined for `XML.Node`.
"""
function parent(o::Raw)
    depth = o.depth
    depth === 0 && return nothing
    p = prev(o)
    while p.depth >= depth
        p = prev(p)
    end
    return p
end

#-----------------------------------------------------------------------------# next Raw
# isspace(x::UInt8) = Base.isspace(Char(x))

# XML whitespace per XML 1.0/1.1 production S:
#   S ::= (#x20 | #x9 | #xD | #xA)+
@inline xml_isspace(b::UInt8)::Bool = (b == 0x20) | (b == 0x09) | (b == 0x0A) | (b == 0x0D)

"""
    next(node) --> typeof(node) or Nothing

Return the next node in the document during depth-first traversal.  Depth-first is the order you
would visit nodes by reading top-down through an XML file.  Not defined for `XML.Node`.
"""
function next(o::Raw)
    if o.has_xml_space # using xml:space context at least once in data
        return next_xml_space(o)
    else # not using xml:space context at all (same as v0.3.5)
        return next_no_xml_space(o)
    end
end

function next_xml_space(o::Raw)
    i = o.pos + o.len + 1
    depth = o.depth
    data = o.data
    type = o.type
    has_xml_space = o.has_xml_space
    ctx = copy(o.ctx)
    last_type = type
    k = findnext(!xml_isspace, data, i)
    if isnothing(k)
        return nothing
    end
    if last_type === RawElementOpen || last_type === RawDocument
        depth += 1
        push!(ctx, ctx[end])  # inherit the xml:space context from parent
        last_type === RawElementOpen && update_ctx!(ctx, o) # check attributes for xml:space and update if necessary
    end
    i = ctx[end] ? i : k
    b = i > 1 ? Char(o.data[i-1]) : Char('<')
    c = Char(o.data[i])
    d = Char(o.data[k+1])
    if c !== '<' || ctx[end] && c === '<' && b === ' ' && last_type === RawElementOpen && d === '/'
        type = RawText
        j = findnext(==(UInt8('<')), data, i) - 1
        j = ctx[end] ? j : findprev(!xml_isspace, data, j) # preserving whitespace if needed
        if last_type === RawElementClose || last_type === RawElementSelfClosed|| last_type === RawDocument
            # Maybe drop pure-whitespace inter-element text nodes?
            # (e.g. whitespace between a closing and an opening tag which would otherwise make an orphan text node)
            #if all(xml_isspace, @view data[i:j]) && depth > 1
            #    return next(Raw(type, depth, j, 0, data, ctx, has_xml_space))
            #end
        end
    else
        i = k
        j = k + 1
        if c === '<'
            c2 = Char(o.data[i+1])
            if c2 === '!'
                c3 = Char(o.data[i+2])
                if c3 === '-'
                    type = RawComment
                    j = findnext(Vector{UInt8}("-->"), data, i)[end]
                elseif c3 === '['
                    type = RawCData
                    j = findnext(Vector{UInt8}("]]>"), data, i)[end]
                elseif c3 === 'D' || c3 == 'd'
                    type = RawDTD
                    j = findnext(==(UInt8('>')), data, i)
                    while sum(==(UInt8('>')), @view data[k:j]) != sum(==(UInt8('<')), @view data[i:j])
                        j = findnext(==(UInt8('>')), data, j + 1)
                    end
                end
            elseif c2 === '?'
                if get_name(data, i + 2)[1] == "xml"
                    type = RawDeclaration
                else
                    type = RawProcessingInstruction
                end
                j = findnext(Vector{UInt8}("?>"), data, i)[end]
            elseif c2 === '/'
                type = RawElementClose
                depth -= 1
                pop!(ctx) # revert to parent xml:space context
                j = findnext(==(UInt8('>')), data, i)
            else
                j = findnext(==(UInt8('>')), data, i)
                if data[j-1] === UInt8('/')
                    type = RawElementSelfClosed
                else
                    type = RawElementOpen
                end
            end
        end
    end
    return Raw(type, depth, i, j - i, data, ctx, has_xml_space)
end

function next_no_xml_space(o::Raw) # same as v0.3.5
    i = o.pos + o.len + 1
    depth = o.depth
    data = o.data
    type = o.type
    has_xml_space = o.has_xml_space
    ctx = [false]
    i = findnext(!xml_isspace, data, i)
    if isnothing(i)
        return nothing
    end
    if type === RawElementOpen || type === RawDocument
        depth += 1
    end
    c = Char(o.data[i])
    d = Char(o.data[i+1])
    if c !== '<'
        type = RawText
        j = findnext(==(UInt8('<')), data, i) - 1
        j = findprev(!xml_isspace, data, j)   # "rstrip"
    elseif c === '<'
        c2 = Char(o.data[i+1])
        if c2 === '!'
            c3 = Char(o.data[i+2])
            if c3 === '-'
                type = RawComment
                j = findnext(Vector{UInt8}("-->"), data, i)[end]
            elseif c3 === '['
                type = RawCData
                j = findnext(Vector{UInt8}("]]>"), data, i)[end]
            elseif c3 === 'D' || c3 == 'd'
                type = RawDTD
                j = findnext(==(UInt8('>')), data, i)
                while sum(==(UInt8('>')), @view data[i:j]) != sum(==(UInt8('<')), @view data[i:j])
                    j = findnext(==(UInt8('>')), data, j + 1)
                end
            end
        elseif c2 === '?'
            if get_name(data, i + 2)[1] == "xml"
                type = RawDeclaration
            else
                type = RawProcessingInstruction
            end
            j = findnext(Vector{UInt8}("?>"), data, i)[end]
        elseif c2 === '/'
            type = RawElementClose
            depth -= 1
            j = findnext(==(UInt8('>')), data, i)
        else
            j = findnext(==(UInt8('>')), data, i)
            if data[j-1] === UInt8('/')
                type = RawElementSelfClosed
            else
                type = RawElementOpen
            end
        end
    end
    return Raw(type, depth, i, j - i, data, ctx, has_xml_space)
end

#-----------------------------------------------------------------------------# prev Raw
"""
    prev(node) --> typeof(node), Nothing, or Missing (only for XML.Node)

Return the previous node in the document during depth-first traversal.  Not defined for `XML.Node`.
"""
function prev(o::Raw)
    if o.has_xml_space # using xml:space context at least once in data
        return prev_xml_space(o)
    else # not using xml:space context at all (same as v0.3.5)
        return prev_no_xml_space(o)
    end
end

function prev_xml_space(o::Raw)
    o.type === RawDocument && return nothing

    idx = _ensure_index_upto!(o, o.pos - 1)
    rec = _find_prev_token(idx.recs, o.pos - 1)
    if rec === nothing
        return Raw(o.data, o.has_xml_space, copy(o.ctx))
    end
    return Raw(rec.type, rec.depth, rec.pos, rec.len, o.data, copy(rec.ctx), o.has_xml_space)
end
function prev_no_xml_space(o::Raw) # same as v0.3.5
    depth = o.depth
    data = o.data
    type = o.type
    has_xml_space = o.has_xml_space
    ctx = has_xml_space ? copy(o.ctx) : [false]
    type === RawDocument && return nothing
    j = o.pos - 1
    j = findprev(!xml_isspace, data, j)
    if isnothing(j)
        return Raw(data, has_xml_space, ctx)  # RawDocument
    end
    c = Char(o.data[j])
    next_type = type
    if c !== '>' # text
        type = RawText
        i = findprev(==(UInt8('>')), data, j) + 1
        i = findnext(!xml_isspace, data, i)  # "lstrip"
    elseif c === '>'
        c2 = Char(o.data[j-1])
        if c2 === '-'
            type = RawComment
            i = findprev(Vector{UInt8}("<--"), data, j)[1]
        elseif c2 === ']'
            type = RawCData
            i = findprev(Vector{UInt8}("<![CDATA["), data, j)[1]
        elseif c2 === '?'
            i = findprev(Vector{UInt8}("<?"), data, j)[1]
            if get_name(data, i + 2)[1] == "xml"
                type = RawDeclaration
            else
                type = RawProcessingInstruction
            end
        else
            i = findprev(==(UInt8('<')), data, j)
            char = Char(data[i+1])
            if char === '/'
                type = RawElementClose
            elseif char === '!'
                type = DTD
            elseif isletter(char) || char === '_'
                type = Char(o.data[j-2]) === '/' ? RawElementSelfClosed : RawElementOpen
            else
                error("Should be unreachable.  Unexpected data: <$char ... $c3$c2$c1>.")
            end
        end
    else
        error("Unreachable reached in XML.prev")
    end
    if type !== RawElementOpen && next_type === RawElementClose
        depth += 1
    elseif type === RawElementOpen && next_type !== RawElementClose
        depth -= 1
    end
    return Raw(type, depth, i, j - i, data, ctx, has_xml_space)
end

