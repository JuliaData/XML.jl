# FlatNode exhaustive in-package benchmark — by regime, median of N runs at the default
# well-formedness level, vs Node/LazyNode/EzXML.
#   julia benchmarks/flatnode_bench.jl   (self-contained temp env: dev XML from this checkout + EzXML)
using Pkg
Pkg.activate(; temp = true, io = devnull)
Pkg.develop(path = joinpath(@__DIR__, ".."), io = devnull)
Pkg.add("EzXML", io = devnull)
using XML, EzXML, Statistics

const xmark = joinpath(@__DIR__, "data", "xmark.xml")
const xml = read(xmark, String)
println("corpus: ", basename(xmark), " (", round(ncodeunits(xml) / 2^20, digits = 1), " MiB)")

# The median RUN's (elapsed, gctime) pair — runs sorted by elapsed, middle one picked whole,
# so the GC figure belongs to the same run as the time it decomposes. GC.gc() first: each run
# starts from a clean heap, so gctime is the run's own allocation cost, not inherited debt.
function medN(f, n = 7)
    runs = [begin GC.gc(); t = @timed f(); (t.time, t.gctime) end for _ in 1:n]
    sort!(runs; by = first)
    runs[cld(n, 2)]
end
_gctail(gc) = gc * 1000 < 0.05 ? "" : string(" (GC ", round(gc * 1000, digits = 1), ")")
allocs(f) = (GC.gc(); Base.gc_num().allocd; a0 = Base.gc_bytes(); f(); Base.gc_bytes() - a0)

# ── build ──
fbuild() = parse(xml, FlatNode)
nbuild() = parse(xml, Node)
ezbuild() = EzXML.parsexml(xml)
for (nm, f) in ["FlatNode" => fbuild, "Node" => nbuild, "EzXML" => ezbuild]
    el, gc = medN(f)
    println("build   ", rpad(nm, 9), lpad(round(el * 1000, digits = 1), 8), " ms", _gctail(gc))
end

# ── traverse (count nodes via each reader's handles) ──
const F = fbuild(); const N = nbuild(); const EZ = ezbuild()
const L = parse(xml, LazyNode)
function lwalk(n, c = Ref(0))
    c[] += 1
    for ch in XML.eachchildnode(n); lwalk(ch, c); end
    c[]
end
function fwalk(n, c = Ref(0))
    c[] += 1
    for ch in XML.eachchildnode(n); fwalk(ch, c); end
    c[]
end
function nwalk(n, c = Ref(0))
    c[] += 1
    for ch in children(n); nwalk(ch, c); end
    c[]
end
function curwalk()
    c = Cursor(xml); n = 0
    while next!(c) !== nothing; n += 1; end
    n
end
println("nodes: flat=", fwalk(FlatNode(F.store, Int32(1))), " node=", nwalk(N), " lazy=", lwalk(L))
for (nm, f) in ["FlatNode" => () -> fwalk(FlatNode(F.store, Int32(1))), "Node" => () -> nwalk(N), "Cursor" => curwalk, "LazyNode" => () -> lwalk(L)]
    el, gc = medN(f)
    println("walk    ", rpad(nm, 9), lpad(round(el * 1000, digits = 2), 8), " ms", _gctail(gc))
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
println("extract sums: flat=", fextract(FlatNode(F.store, Int32(1))), " node=", nextract(N))
for (nm, f) in ["FlatNode" => () -> fextract(FlatNode(F.store, Int32(1))), "Node" => () -> nextract(N)]
    el, gc = medN(f)
    println("extract ", rpad(nm, 9), lpad(round(el * 1000, digits = 2), 8), " ms", _gctail(gc))
end

# ── retained + build allocations ──
println("retained  FlatNode ", lpad(round(Base.summarysize(F.store) / 2^20, digits = 1), 7), " MiB   ",
        "Node ", lpad(round(Base.summarysize(N) / 2^20, digits = 1), 7), " MiB")
println("buildalloc FlatNode ", lpad(round(allocs(fbuild) / 2^20, digits = 1), 6), " MiB   ",
        "Node ", lpad(round(allocs(nbuild) / 2^20, digits = 1), 6), " MiB")

# ── GC pressure: full collection time with the tree live ──
gcms(x) = (GC.gc(); t = @elapsed GC.gc(true); t * 1000)
println("GC full  with FlatNode live ", round(gcms(F), digits = 2), " ms   with Node live ", round(gcms(N), digits = 2), " ms")
