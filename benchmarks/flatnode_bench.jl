# Per-reader benchmark behind Table 5 of PERFORMANCE-v0.4.md and the README
# "Performance by access pattern" table, and the handle and query entry points
# no other script exercises — BenchmarkTools throughout, default
# parameters, 5 s budget per cell: samples run back-to-back, each printed number
# is the median sample's time with the median GC share as its "(GC x)" tail
# (omitted below 0.05 ms). "alloc" is one call's allocation total (Julia heap);
# "retained" is Base.summarysize of the live DOM — facts, not timings.
#
#   julia --project=benchmarks benchmarks/flatnode_bench.jl
#   julia --project=benchmarks benchmarks/flatnode_bench.jl --gc-only
#   julia --project=benchmarks --gcthreads=4 benchmarks/flatnode_bench.jl --gc-only
#
# --gc-only measures one thing: a full collection with the built `Node` tree as
# the live set (the GC-tuning [!TIP] of PERFORMANCE-v0.4.md) — run it with and
# without --gcthreads to reproduce the pair of figures quoted there.
using XML, EzXML, BenchmarkTools

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5

const xmark = joinpath(@__DIR__, "data", "xmark.xml")
const xml = read(xmark, String)
println("document: ", basename(xmark), " (", round(ncodeunits(xml) / 2^20, digits = 1),
        " MiB)   julia ", VERSION, "   gcthreads ", Threads.ngcthreads())

_tail(gc) = gc < 0.05 ? "" : string(" (GC ", round(gc, digits = 1), ")")
function cell(label, b; alloc = false)
    m = median(b)
    print(rpad(label, 22), lpad(round(m.time / 1e6, digits = 2), 9), " ms",
          rpad(_tail(m.gctime / 1e6), 12))
    alloc && print(lpad(round(b.memory / 2^20, digits = 1), 7), " MiB alloc")
    println()
end

function nwalk(n, c = Ref(0))
    c[] += 1
    for ch in children(n); nwalk(ch, c); end
    c[]
end

if "--gc-only" in ARGS
    const N0 = parse(xml, Node)
    println("live tree: ", nwalk(N0), " nodes")
    cell("GC full, Node live", @benchmark GC.gc(true) evals = 1)
    exit(0)
end

# ── build (the whole `parse` call) ──
cell("build FlatNode", @benchmark(parse($xml, FlatNode)); alloc = true)
cell("build Node",     @benchmark(parse($xml, Node));     alloc = true)
# The C tree is freed per sample outside the timing, through the document's node, which is where
# EzXML attaches its finalizer; Julia alloc is not meaningful for it.
cell("build EzXML",    @benchmark((d[] = EzXML.parsexml($xml)), setup = (d = Ref{Any}(nothing)), teardown = (d[] === nothing || finalize(d[].node); d[] = nothing)))
# LazyNode materializes nothing, so its "build" is the document entry alone: one line-end
# scan of the source (§2.11), allocation-free, proportional to document size.
cell("open LazyNode",  @benchmark(parse($xml, LazyNode));  alloc = true)

# ── handles for the access benchmarks ──
const F = parse(xml, FlatNode)
const N = parse(xml, Node)
const L = parse(xml, LazyNode)
flatroot() = FlatNode(F.store, Int32(1))

function fwalk(n, c = Ref(0))
    c[] += 1
    for ch in XML.eachchildnode(n); fwalk(ch, c); end
    c[]
end
function lwalk(n, c = Ref(0))
    c[] += 1
    for ch in XML.eachchildnode(n); lwalk(ch, c); end
    c[]
end
function curwalk(s)
    c = Cursor(s); n = 0
    while next!(c) !== nothing; n += 1; end
    n
end

# ── extract (tag/value byte sums through the public accessors) ──
function fextract(n, acc = Ref(0))
    t = tag(n); v = value(n)
    t === nothing || (acc[] += ncodeunits(t)); v === nothing || (acc[] += ncodeunits(v))
    for ch in XML.eachchildnode(n); fextract(ch, acc); end
    acc[]
end
function nextract(n, acc = Ref(0))
    t = tag(n); v = value(n)
    t === nothing || (acc[] += ncodeunits(t)); v === nothing || (acc[] += ncodeunits(v))
    for ch in children(n); nextract(ch, acc); end
    acc[]
end

println("nodes: flat=", fwalk(flatroot()), " node=", nwalk(N), " lazy=", lwalk(L),
        " cursor=", curwalk(xml))
println("extract sums: flat=", fextract(flatroot()), " node=", nextract(N))

cell("walk FlatNode",  @benchmark fwalk(flatroot()))
cell("walk Node",      @benchmark nwalk($N))
cell("walk Cursor",    @benchmark curwalk($xml))
cell("walk LazyNode",  @benchmark lwalk($L))

cell("extract FlatNode", @benchmark fextract(flatroot()))
cell("extract Node",     @benchmark nextract($N))

println("retained  FlatNode ", lpad(round(Base.summarysize(F.store) / 2^20, digits = 1), 7),
        " MiB   Node ", lpad(round(Base.summarysize(N) / 2^20, digits = 1), 7), " MiB")

# ── the handle and query entry points ──
# One `item` element, the 1000th in document order, addressed in every reader: the entry points no
# other script exercises. `sourcespan`, `splicetext` and `issamenode` belong to the two
# source-retaining readers; `depth`, `siblings` and `xpath` search from a `Node` root, which keeps
# no parent links; `foreach_attr` is the token-level attribute loop of `LazyNode`, shown beside the
# decoded `eachattribute` on the same element.
function nth_item(n, k, childiter, c = Ref(0))
    if XML.nodetype(n) === XML.Element && XML.tag(n) == "item"
        c[] += 1
        c[] == k && return n
    end
    for ch in childiter(n)
        r = nth_item(ch, k, childiter, c)
        r === nothing || return r
    end
    nothing
end
const ITEM_F = nth_item(flatroot(), 1000, XML.eachchildnode)
const ITEM_L = nth_item(L, 1000, XML.eachchildnode)
const ITEM_N = nth_item(N, 1000, n -> something(children(n), ()))
const ITEM_PATH = "/site/regions/asia/item[500]"
println("target: item #1000  depth FlatNode=", XML.depth(ITEM_F), " Node=", XML.depth(ITEM_N, N),
        "  same span in FlatNode and LazyNode: ", XML.sourcespan(ITEM_F) == XML.sourcespan(ITEM_L),
        "  xpath finds it: ", XML.xpath(N, ITEM_PATH) == [ITEM_N])

# The accumulator is a global so the closure captures nothing and allocates nothing.
const ATTR_ACC = Ref(0)
function attr_tokens(n)
    ATTR_ACC[] = 0
    XML.foreach_attr((k, v) -> (ATTR_ACC[] += k.ncodeunits + v.ncodeunits), n)
    ATTR_ACC[]
end
function attr_pairs(n)
    acc = 0
    for (k, v) in XML.eachattribute(n); acc += sizeof(k) + sizeof(v); end
    acc
end

_fine(t) = t < 1e3 ? string(round(t, digits = 1), " ns") :
           t < 1e6 ? string(round(t / 1e3, digits = 2), " µs") :
                     string(round(t / 1e6, digits = 2), " ms")
function ucell(label, b)
    println(rpad(label, 28), lpad(_fine(median(b).time), 11), lpad(b.allocs, 9), " allocs",
            lpad(round(b.memory / 2^20, digits = 2), 8), " MiB")
end

ucell("sourcespan FlatNode",    @benchmark XML.sourcespan($ITEM_F))
ucell("sourcespan LazyNode",    @benchmark XML.sourcespan($ITEM_L))
ucell("splicetext FlatNode",    @benchmark XML.splicetext($ITEM_F))
ucell("splicetext LazyNode",    @benchmark XML.splicetext($ITEM_L))
ucell("issamenode FlatNode",    @benchmark XML.issamenode($ITEM_F, $ITEM_F))
ucell("issamenode LazyNode",    @benchmark XML.issamenode($ITEM_L, $ITEM_L))
ucell("depth FlatNode",         @benchmark XML.depth($ITEM_F))
ucell("depth Node, search",     @benchmark XML.depth($ITEM_N, $N))
ucell("siblings Node, search",  @benchmark XML.siblings($ITEM_N, $N))
ucell("foreach_attr LazyNode",  @benchmark attr_tokens($ITEM_L))
ucell("eachattribute LazyNode", @benchmark attr_pairs($ITEM_L))
ucell("xpath, positional path", @benchmark XML.xpath($N, $ITEM_PATH))
ucell("xpath, //item[@featured]", @benchmark XML.xpath($N, "//item[@featured='yes']"))
