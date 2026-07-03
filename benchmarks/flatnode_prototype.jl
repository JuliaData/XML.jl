# benchmarks/flatnode_prototype.jl
#
# PROTOTYPE — a flat node store ("FlatNode"): the whole document as ONE contiguous
# Vector of isbits records with integer index links (parent / first_child /
# next_sibling), plus a side Vector for attributes — instead of Node's per-node heap
# objects. Zero-copy: records hold byte ranges into the source (Node{SubString}
# semantics: entities left raw).
#
# Goal: validate the PERFORMANCE-v0.4.md hypothesis that the whole full-DOM gap to
# libxml2 is *materialising* the pointer tree — i.e. this layout should build faster,
# retain far less, and collapse the Julia-GC mark cost (a pointerfree Vector is one GC
# leaf vs ~2.5n pointer-bearing objects). NOT shipped in v0.4; candidate for v0.5.
#
#   julia --project=benchmarks benchmarks/flatnode_prototype.jl

module FlatNodePrototype

using XML
using XML.XMLTokenizer: TokenKinds, tokenize, raw, tag_name, attr_value, pi_target

#-----------------------------------------------------------------------------# records
struct FlatAttr                       # isbits, 16 B
    name_offset::Int32; name_len::Int32
    value_offset::Int32; value_len::Int32
end

struct FlatNode                       # isbits, no pointers
    kind::XML.NodeType
    parent::Int32
    first_child::Int32
    next_sibling::Int32
    name_offset::Int32; name_len::Int32     # Element tag / PI target
    value_offset::Int32; value_len::Int32   # Text/Comment/CData/DTD/PI content
    attr_first::Int32; attr_count::Int32
end

struct FlatDocument
    source::String
    nodes::Vector{FlatNode}           # nodes[1] = the Document node
    attrs::Vector{FlatAttr}
end

@assert isbitstype(FlatNode) && isbitstype(FlatAttr)

# byte range of a SubString into its (root) parent string
@inline _rng(s::SubString{String}) = (Int32(s.offset), Int32(s.ncodeunits))

# record-update helpers (structs are immutable; rebuild in place)
@inline _set_first_child(n::FlatNode, i::Int32) =
    FlatNode(n.kind, n.parent, i, n.next_sibling, n.name_offset, n.name_len, n.value_offset, n.value_len, n.attr_first, n.attr_count)
@inline _set_next_sibling(n::FlatNode, i::Int32) =
    FlatNode(n.kind, n.parent, n.first_child, i, n.name_offset, n.name_len, n.value_offset, n.value_len, n.attr_first, n.attr_count)
@inline _set_value(n::FlatNode, off::Int32, len::Int32) =
    FlatNode(n.kind, n.parent, n.first_child, n.next_sibling, n.name_offset, n.name_len, off, len, n.attr_first, n.attr_count)
@inline _add_attr(n::FlatNode, first::Int32) =
    FlatNode(n.kind, n.parent, n.first_child, n.next_sibling, n.name_offset, n.name_len, n.value_offset, n.value_len,
             n.attr_first == 0 ? first : n.attr_first, n.attr_count + Int32(1))

# wire node `idx` as the next child of the current open parent; returns the parent index
@inline function _attach!(nodes::Vector{FlatNode}, pstack::Vector{Int32}, lastchild::Vector{Int32}, idx::Int32)
    p = @inbounds pstack[end]
    lc = @inbounds lastchild[end]
    if lc == 0
        @inbounds nodes[p] = _set_first_child(nodes[p], idx)
    else
        @inbounds nodes[lc] = _set_next_sibling(nodes[lc], idx)
    end
    @inbounds lastchild[end] = idx
    p
end

#-----------------------------------------------------------------------------# builder (single VPA pass, lenient)
function flat_parse(xml::String)
    ncodeunits(xml) <= typemax(Int32) || error("FlatNode prototype: source larger than 2 GiB")
    nodes = FlatNode[]
    attrs = FlatAttr[]
    sizehint!(nodes, ncodeunits(xml) >> 4)
    push!(nodes, FlatNode(XML.Document, Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0)))
    pstack    = Int32[1]
    lastchild = Int32[0]
    K = TokenKinds

    cur = Int32(0)                    # node receiving ATTR_* (open element or XML decl)
    pend = Int32(0)                   # node awaiting its *_CONTENT (PI) — filled in place
    pan_off = Int32(0); pan_len = Int32(0)   # pending attribute name

    for token in tokenize(xml)
        k = token.kind
        if k === K.TEXT
            off, len = _rng(raw(token, xml))
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.Text, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))

        elseif k === K.OPEN_TAG
            noff, nlen = _rng(tag_name(token, xml))
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.Element, p, Int32(0), Int32(0), noff, nlen, Int32(0), Int32(0), Int32(0), Int32(0)))
            push!(pstack, idx); push!(lastchild, Int32(0))
            cur = idx

        elseif k === K.SELF_CLOSE
            pop!(pstack); pop!(lastchild)

        elseif k === K.CLOSE_TAG
            pop!(pstack); pop!(lastchild)

        elseif k === K.ATTR_NAME
            pan_off, pan_len = _rng(raw(token, xml))

        elseif k === K.ATTR_VALUE
            voff, vlen = _rng(attr_value(token, xml))
            push!(attrs, FlatAttr(pan_off, pan_len, voff, vlen))
            @inbounds nodes[cur] = _add_attr(nodes[cur], Int32(length(attrs)))

        elseif k === K.XML_DECL_OPEN
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.Declaration, p, Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0)))
            cur = idx

        elseif k === K.COMMENT_CONTENT
            off, len = _rng(raw(token, xml))
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.Comment, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))

        elseif k === K.CDATA_CONTENT
            off, len = _rng(raw(token, xml))
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.CData, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))

        elseif k === K.DOCTYPE_CONTENT
            off, len = _rng(lstrip(raw(token, xml)))         # mirror _parse: lstrip'd DTD value
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.DTD, p, Int32(0), Int32(0), Int32(0), Int32(0), off, len, Int32(0), Int32(0)))

        elseif k === K.PI_OPEN
            noff, nlen = _rng(pi_target(token, xml))
            idx = Int32(length(nodes) + 1)
            p = _attach!(nodes, pstack, lastchild, idx)
            push!(nodes, FlatNode(XML.ProcessingInstruction, p, Int32(0), Int32(0), noff, nlen, Int32(0), Int32(0), Int32(0), Int32(0)))
            pend = idx

        elseif k === K.PI_CONTENT
            s = lstrip(raw(token, xml))                      # mirror _parse: lstrip'd, empty → none
            if !isempty(s)
                off, len = _rng(s)
                @inbounds nodes[pend] = _set_value(nodes[pend], off, len)
            end
        end
        # TAG_CLOSE / *_OPEN(comment,cdata) / *_CLOSE(comment,cdata,pi,decl,doctype): no tree action
    end
    FlatDocument(xml, nodes, attrs)
end

#-----------------------------------------------------------------------------# accessors
@inline _sub(d::FlatDocument, off::Int32, len::Int32) =
    @inbounds SubString(d.source, off + 1, prevind(d.source, off + len + 1))

flat_tag(d::FlatDocument, i::Integer)   = (n = d.nodes[i]; n.name_len  > 0 ? _sub(d, n.name_offset,  n.name_len)  : nothing)
flat_value(d::FlatDocument, i::Integer) = (n = d.nodes[i]; n.value_len > 0 ? _sub(d, n.value_offset, n.value_len) : nothing)

# document-order traversal via the index links — no stack, no allocation
function flat_walk(d::FlatDocument)
    nodes = d.nodes
    cnt = 0; acc = 0
    i = Int32(1)
    @inbounds while i != 0
        n = nodes[i]
        cnt += 1
        acc += Int(n.name_len) + Int(n.value_len)      # == sizeof(tag) + sizeof(value)
        if n.first_child != 0
            i = n.first_child
        else
            while i != 0 && nodes[i].next_sibling == 0
                i = nodes[i].parent
            end
            i == 0 && break
            i = nodes[i].next_sibling
        end
    end
    (cnt, acc)
end

#-----------------------------------------------------------------------------# validation vs Node{SubString}
# Same tree, byte-for-byte: kind, tag/target, raw value, attributes (names + values), shape.
function validate(d::FlatDocument, doc::XML.Node)
    issues = String[]
    function cmp(fi::Int32, n)
        length(issues) > 20 && return
        f = d.nodes[fi]
        XML.nodetype(n) === f.kind || push!(issues, "kind@$fi: flat=$(f.kind) node=$(XML.nodetype(n))")
        isequal(XML.tag(n), flat_tag(d, fi)) || push!(issues, "tag@$fi: $(repr(flat_tag(d, fi))) vs $(repr(XML.tag(n)))")
        isequal(XML.value(n), flat_value(d, fi)) || push!(issues, "value@$fi: $(repr(flat_value(d, fi))) vs $(repr(XML.value(n)))")
        na = XML.attributes(n)
        ncount = na === nothing ? 0 : length(na)
        Int(f.attr_count) == ncount || push!(issues, "attr count@$fi: $(f.attr_count) vs $ncount")
        if na !== nothing && Int(f.attr_count) == ncount
            ai = f.attr_first
            for (k, v) in na
                a = d.attrs[ai]
                isequal(k, _sub(d, a.name_offset, a.name_len))   || push!(issues, "attr name@$fi: $(repr(_sub(d, a.name_offset, a.name_len))) vs $(repr(k))")
                isequal(v, _sub(d, a.value_offset, a.value_len)) || push!(issues, "attr val@$fi/$k")
                ai += Int32(1)
            end
        end
        ch = XML.children(n)
        ci = f.first_child
        if ch !== nothing
            for c in ch
                ci == 0 && (push!(issues, "missing child under @$fi"); return)
                cmp(ci, c)
                ci = d.nodes[ci].next_sibling
            end
        end
        ci == 0 || push!(issues, "extra flat child under @$fi")
    end
    cmp(Int32(1), doc)
    issues
end

end # module

#-----------------------------------------------------------------------------# run: validate, then measure
# (Guarded so the file is includable for the module alone — e.g. by the isolated GC probe.
#  The `using`s stay OUTSIDE the guard: macros like @benchmark must be defined at lowering
#  time even when the guarded block does not run.)
using XML, BenchmarkTools, Statistics
using .FlatNodePrototype: FlatNodePrototype, flat_parse, flat_walk, FlatDocument

if abspath(PROGRAM_FILE) == @__FILE__

const FNP = FlatNodePrototype
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5
const SSNode = Node{SubString{String}}

# --- correctness on three inputs ---
snippet = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE root [<!ENTITY x "y">]>
<!-- a comment -->
<root a="1" b="two">
  text &amp; more
  <selfclosed x="1"/>
  <café δ="ünï">nested <b>deep</b> tail</café>
  <![CDATA[raw <cdata> &amp; bytes]]>
  <?pi target content ?>
  <empty></empty>
</root>
<!-- trailing -->
"""
books = read(joinpath(@__DIR__, "..", "test", "data", "books.xml"), String)
xmark_file = joinpath(@__DIR__, "data", "xmark.xml")
isfile(xmark_file) || error("generate xmark.xml first (run benchmarks.jl or profile.jl)")
xmark = read(xmark_file, String)

for (name, s) in (("snippet", snippet), ("books.xml", books), ("xmark 14MB", xmark))
    issues = FNP.validate(flat_parse(s), parse(s, SSNode))
    println("validate vs Node{SubString} — ", rpad(name, 12), isempty(issues) ? "OK" : "FAILED")
    foreach(x -> println("    ", x), issues)
    isempty(issues) || error("validation failed on $name")
end

# --- measurements on xmark ---
fd   = flat_parse(xmark)
tree = parse(xmark, Node)
ss   = parse(xmark, SSNode)

function xml_walk(node)      # same walk as benchmarks/profile.jl
    cnt = 1; acc = 0
    t = XML.tag(node);   t === nothing || (acc += sizeof(t))
    v = XML.value(node); v === nothing || (acc += sizeof(v))
    ch = XML.children(node)
    if ch !== nothing
        for k in ch
            c2, a2 = xml_walk(k); cnt += c2; acc += a2
        end
    end
    (cnt, acc)
end
@assert flat_walk(fd)[1] == xml_walk(tree)[1]  # same node count

ms(b)  = round(median(b).time / 1e6, digits = 2)
mib(b) = round(b.memory / 2^20, digits = 1)
mibsz(x) = round(Base.summarysize(x) / 2^20, digits = 1)

println("\nnodes: ", length(fd.nodes), "  attrs: ", length(fd.attrs),
        "  (", round(ncodeunits(xmark) / 1e6, digits = 2), " MB source)")

b_flat = @benchmark flat_parse($xmark)
b_node = @benchmark parse($xmark, Node)
b_ss   = @benchmark parse($xmark, SSNode)
println("\n=== BUILD (parse the 14 MB document) ===")
println(rpad("  FlatNode (flat store)", 30), lpad(ms(b_flat), 8), " ms   ", lpad(mib(b_flat), 7), " MiB alloc")
println(rpad("  Node{String}", 30),          lpad(ms(b_node), 8), " ms   ", lpad(mib(b_node), 7), " MiB alloc")
println(rpad("  Node{SubString}", 30),       lpad(ms(b_ss), 8),   " ms   ", lpad(mib(b_ss), 7),   " MiB alloc")

w_flat = @benchmark flat_walk($fd)
w_node = @benchmark $xml_walk($tree)
w_ss   = @benchmark $xml_walk($ss)
println("\n=== TRAVERSE (full walk, count + bytes touched) ===")
println(rpad("  FlatNode", 30), lpad(ms(w_flat), 8), " ms")
println(rpad("  Node{String}", 30), lpad(ms(w_node), 8), " ms")
println(rpad("  Node{SubString}", 30), lpad(ms(w_ss), 8), " ms")

println("\n=== RETAINED MEMORY (Base.summarysize) ===")
println(rpad("  FlatNode (nodes+attrs+src)", 30), lpad(mibsz(fd), 8), " MiB")
println(rpad("  Node{String}", 30), lpad(mibsz(tree), 8), " MiB")
println(rpad("  Node{SubString} (excl. src)", 30), lpad(mibsz(ss), 8), " MiB")

# --- GC mark cost while each structure is live ---
function gc_ms()
    ts = Float64[]
    for _ in 1:5
        t0 = time_ns(); GC.gc(true); push!(ts, (time_ns() - t0) / 1e6)
    end
    minimum(ts)
end
holder = Any[fd, tree, ss]
t_all = gc_ms()
holder[2] = nothing; holder[3] = nothing; GC.gc(true)   # only flat live
t_flat = gc_ms()
holder[1] = nothing; GC.gc(true)
t_none = gc_ms()
Base.donotdelete(holder)
println("\n=== FULL-GC PAUSE (min of 5; in-process, INDICATIVE ONLY — top-level globals keep")
println("    structures reachable, so use the isolated-process probe for real deltas) ===")
println("  everything live:  ", round(t_all,  digits = 1), " ms")
println("  only flat live:   ", round(t_flat, digits = 1), " ms")
println("  nothing live:     ", round(t_none, digits = 1), " ms")

end # if run as a script
