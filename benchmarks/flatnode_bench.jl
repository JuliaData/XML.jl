# Per-reader benchmark behind Table 4 of PERFORMANCE-v0.4.md and the README
# "Performance by access pattern" table — BenchmarkTools throughout, default
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
println("corpus: ", basename(xmark), " (", round(ncodeunits(xml) / 2^20, digits = 1),
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
cell("build EzXML",    @benchmark(EzXML.parsexml($xml)))   # C-heap tree: Julia alloc not meaningful
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
