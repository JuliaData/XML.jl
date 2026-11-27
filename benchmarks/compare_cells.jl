# benchmarks/compare_cells.jl
#
# What `compare.jl` measures in each process, on the version of XML.jl that the process
# loads. Prints one line per cell: its name, a tab, and its time in nanoseconds, net of
# garbage collection. A cell that the loaded version cannot run prints NaN.
#
# The cells take turns in rounds of one second, so that a drift of the machine does not
# fall on one of them. The time of a cell is the median of its rounds, each one the median
# of its samples.
#
# To measure something else, copy this file in this folder, change `CELLS`, and pass the
# copy to `compare.jl` with `--cells=`.
#
#   julia --project=benchmarks benchmarks/compare_cells.jl [rounds]

using XML, BenchmarkTools, Statistics

const ROUNDS = isempty(ARGS) ? 3 : parse(Int, ARGS[1])

include(joinpath(@__DIR__, "XMarkGenerator.jl"))
using .XMarkGenerator
const FILE = joinpath(@__DIR__, "data", "xmark.xml")
if !isfile(FILE)
    mkpath(dirname(FILE)); generate_xmark(FILE, 1.0)
end

# The XMark-style document of the other scripts, its character data alone, and a document
# whose DOCTYPE declares an entity that each of its 200 000 elements references.
const S = read(FILE, String)
const TEXT = string("<doc>", replace(S, r"<[^>]*>" => ""), "</doc>")
const ENTITIES = string("<!DOCTYPE r [<!ENTITY e \"lorem\">]><r>",
                        repeat("<a>ipsum &e; dolor</a>", 200_000), "</r>")
const TREE = parse(S, Node)

function stream(s)
    c = XML.Cursor(s); n = 0
    while XML.next!(c) !== nothing
        n += 1
    end
    n
end

const CELLS = [
    "parse to Node"                    => () -> parse(S, Node),
    "parse to Node, :strict"           => () -> parse(S, Node; wellformed = :strict),
    "parse to Node{SubString}"         => () -> parse(S, Node{SubString{String}}),
    "parse to FlatNode"                => () -> parse(S, FlatNode),
    "Cursor stream"                    => () -> stream(S),
    "write"                            => () -> XML.write(TREE),
    "parse, text alone, :strict"       => () -> parse(TEXT, Node; wellformed = :strict),
    "parse, 200 000 entity references" => () -> parse(ENTITIES, Node),
]

net(t) = median(t.times .- t.gctimes)

function measure(cells, rounds)
    runs = trues(length(cells))
    # A first call compiles each cell, and finds those that this version lacks.
    for (k, (_, f)) in enumerate(cells)
        try
            f()
        catch
            runs[k] = false
        end
    end
    bs = [@benchmarkable($f()) for (_, f) in cells]
    times = [Float64[] for _ in cells]
    for _ in 1:rounds, k in eachindex(bs)
        runs[k] || continue
        push!(times[k], net(run(bs[k]; seconds = 1, samples = 100_000, evals = 1)))
    end
    [runs[k] ? median(times[k]) : NaN for k in eachindex(cells)]
end

for ((name, _), t) in zip(CELLS, measure(CELLS, ROUNDS))
    println(name, '\t', t)
end
