using XML
using BenchmarkTools

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5

#-----------------------------------------------------------------------------# Setup
sizes = [2, 5, 10, 20]

function make_xml(n::Int)
    attrs = join((" attr$i=\"value$i\"" for i in 1:n))
    "<root$attrs/>"
end

function make_pairs(n::Int)
    Pair{String,String}["attr$i" => "value$i" for i in 1:n]
end

pt(t) = BenchmarkTools.prettytime(t)

function printrow(n, op, t_dict, t_attr)
    pct = round(100 * (t_dict - t_attr) / t_dict, digits=1)
    label = pct > 0 ? "$(pct)% faster" : "$(-pct)% slower"
    println(rpad("$n attrs", 10), " | ", rpad(op, 22), " | ",
            rpad("Dict $(pt(t_dict))", 22), " | ",
            rpad("Attributes $(pt(t_attr))", 26), " | ", label)
end

#-----------------------------------------------------------------------------# Benchmarks
println("=" ^ 110)
println("  Attributes vs Dict Benchmarks")
println("=" ^ 110)
println(rpad("Size", 10), " | ", rpad("Operation", 22), " | ",
        rpad("Dict", 22), " | ", rpad("Attributes", 26), " | Change")
println("-" ^ 110)

for n in sizes
    pairs = make_pairs(n)
    d = Dict(pairs)
    a = XML.Attributes(pairs)
    key_mid = "attr$(n ÷ 2 + 1)"
    key_last = "attr$n"

    tests = [
        ("construct",       () -> @benchmark(Dict($pairs)),               () -> @benchmark(XML.Attributes($pairs))),
        ("getindex [mid]",  () -> @benchmark($d[$key_mid]),               () -> @benchmark($a[$key_mid])),
        ("getindex [last]", () -> @benchmark($d[$key_last]),              () -> @benchmark($a[$key_last])),
        ("get [miss]",      () -> @benchmark(get($d, "nope", nothing)),   () -> @benchmark(get($a, "nope", nothing))),
        ("haskey [hit]",    () -> @benchmark(haskey($d, $key_mid)),       () -> @benchmark(haskey($a, $key_mid))),
        ("keys",            () -> @benchmark(collect(keys($d))),          () -> @benchmark(keys($a))),
        ("iterate",         () -> @benchmark(sum(length(v) for (_,v) in $d)), () -> @benchmark(sum(length(v) for (_,v) in $a))),
    ]

    for (op, bench_dict, bench_attr) in tests
        t_dict = median(bench_dict()).time
        t_attr = median(bench_attr()).time
        printrow(n, op, t_dict, t_attr)
    end
    println("-" ^ 110)
end

#-----------------------------------------------------------------------------# End-to-end: attributes() call on parsed Node
println()
println(rpad("Size", 10), " | ", rpad("Operation", 22), " | Time")
println("-" ^ 50)
for n in sizes
    doc = parse(make_xml(n), Node)
    el = doc[1]
    t = median(@benchmark(attributes($el))).time
    println(rpad("$n attrs", 10), " | ", rpad("attributes(node)", 22), " | ", pt(t))
end
println()
