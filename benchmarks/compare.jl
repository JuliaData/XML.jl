#= Compare current dev XML.jl against the last released version.

Usage:
    julia benchmarks/compare.jl [tag]

`tag` defaults to the latest git tag (e.g. v0.3.8).

This script:
1. Runs benchmarks using the current (dev) code
2. Checks out the release tag into a temp worktree
3. Runs the same benchmarks against that version
4. Prints a side-by-side comparison
=#

using BenchmarkTools, Serialization, InteractiveUtils

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5
BenchmarkTools.DEFAULT_PARAMETERS.samples = 10000

const ROOT = dirname(@__DIR__)

const RELEASE_TAG = if length(ARGS) >= 1
    ARGS[1]
else
    tags = readlines(`git -C $ROOT tag --sort=version:refname`)
    filter!(t -> startswith(t, "v"), tags)
    last(tags)
end

const SMALL_FILE = joinpath(ROOT, "test", "data", "books.xml")
const SMALL_XML = read(SMALL_FILE, String)

# Generate medium file if needed
include(joinpath(ROOT, "benchmarks", "XMarkGenerator.jl"))
using .XMarkGenerator
const MEDIUM_FILE = joinpath(ROOT, "benchmarks", "data", "xmark.xml")
if !isfile(MEDIUM_FILE)
    mkpath(dirname(MEDIUM_FILE))
    @info "Generating XMark benchmark XML..."
    generate_xmark(MEDIUM_FILE, 1.0)
end
const MEDIUM_XML = read(MEDIUM_FILE, String)

#-----------------------------------------------------------------------------# Helpers
function _collect_tags!(out, node)
    for c in XML.children(node)
        if XML.nodetype(c) === XML.Element
            push!(out, XML.tag(c))
            _collect_tags!(out, c)
        end
    end
end

function bench_collect_tags(node)
    out = String[]
    _collect_tags!(out, node)
    out
end

#-----------------------------------------------------------------------------# Run dev benchmarks
println("="^60)
println("  XML.jl Benchmark Comparison")
println("  Current (dev) vs $RELEASE_TAG")
println("="^60)
println()

print("Running dev benchmarks...")
flush(stdout)

using XML

dev_results = Dict{String, BenchmarkTools.Trial}()

const SSNode = Node{SubString{String}}

dev_small = parse(SMALL_XML, Node)
dev_small_ss = parse(SMALL_XML, SSNode)
dev_medium = parse(MEDIUM_XML, Node)
dev_medium_ss = parse(MEDIUM_XML, SSNode)

dev_results["Parse (small), String"] = @benchmark parse($SMALL_XML, Node)
dev_results["Parse (small), SubString"] = @benchmark parse($SMALL_XML, SSNode)
dev_results["Parse (medium), String"] = @benchmark parse($MEDIUM_XML, Node)
dev_results["Parse (medium), SubString"] = @benchmark parse($MEDIUM_XML, SSNode)
dev_results["Write (small)"] = @benchmark XML.write($dev_small)
dev_results["Write (medium)"] = @benchmark XML.write($dev_medium)
dev_results["Read file (medium), String"] = @benchmark read($MEDIUM_FILE, Node)
dev_results["Read file (medium), SubString"] = @benchmark parse(read($MEDIUM_FILE, String), SSNode)
dev_results["Collect tags (small), String"] = @benchmark bench_collect_tags($dev_small)
dev_results["Collect tags (small), SubString"] = @benchmark bench_collect_tags($dev_small_ss)
dev_results["Collect tags (medium), String"] = @benchmark bench_collect_tags($dev_medium)
dev_results["Collect tags (medium), SubString"] = @benchmark bench_collect_tags($dev_medium_ss)

# LazyNode benchmarks
dev_lazy_small = parse(SMALL_XML, LazyNode)
dev_lazy_medium = parse(MEDIUM_XML, LazyNode)

dev_results["Parse (small), LazyNode"] = @benchmark parse($SMALL_XML, LazyNode)
dev_results["Parse (medium), LazyNode"] = @benchmark parse($MEDIUM_XML, LazyNode)
dev_results["Write (small), LazyNode"] = @benchmark XML.write($(dev_lazy_small[1]))
dev_results["Write (medium), LazyNode"] = @benchmark XML.write($(dev_lazy_medium[1]))
dev_results["sourcetext, small"] = @benchmark sourcetext($(dev_lazy_small[1]))
dev_results["sourcetext, medium"] = @benchmark sourcetext($(dev_lazy_medium[1]))
dev_lazy_medium_root = let ch = children(dev_lazy_medium)
    i = findfirst(c -> nodetype(c) === Element, ch)
    ch[i]
end
dev_results["children vs eachchildnode, children"] = @benchmark children($dev_lazy_medium_root)
dev_results["children vs eachchildnode, eachchildnode"] = @benchmark collect(eachchildnode($dev_lazy_medium_root))

# SST-like benchmark: many children, write each one
const SST_N = 10_000
const SST_XML = "<sst>" * join("""<si><t>string_$i</t></si>""" for i in 1:SST_N) * "</sst>"
dev_sst_node = parse(SST_XML, Node)
dev_sst_lazy = parse(SST_XML, LazyNode)
dev_sst_root_node = only(children(dev_sst_node))
dev_sst_root_lazy = only(children(dev_sst_lazy))

function bench_sst_node(xml)
    root = only(children(parse(xml, Node)))
    out = String[]
    for c in XML.children(root)
        XML.nodetype(c) === XML.Element && push!(out, XML.write(c))
    end
    out
end
function bench_sst_lazy_children(xml)
    root = only(children(parse(xml, LazyNode)))
    out = String[]
    for c in XML.children(root)
        XML.nodetype(c) === XML.Element && push!(out, XML.write(c))
    end
    out
end
function bench_sst_lazy_eachchildnode(xml)
    root = only(children(parse(xml, LazyNode)))
    out = String[]
    for c in XML.eachchildnode(root)
        XML.nodetype(c) === XML.Element && push!(out, XML.write(c))
    end
    out
end

dev_results["SST (parse+iterate+write), Node"] = @benchmark bench_sst_node($SST_XML)
dev_results["SST (parse+iterate+write), LazyNode+children"] = @benchmark bench_sst_lazy_children($SST_XML)
dev_results["SST (parse+iterate+write), LazyNode+eachchildnode"] = @benchmark bench_sst_lazy_eachchildnode($SST_XML)

println(" done")

#-----------------------------------------------------------------------------# Run release benchmarks via temp worktree + separate process
print("Setting up $RELEASE_TAG worktree...")
flush(stdout)

worktree_dir = mktempdir()
run(pipeline(`git -C $ROOT worktree add $worktree_dir $RELEASE_TAG`, stdout=devnull, stderr=devnull))
println(" done")

release_results_file = joinpath(worktree_dir, "_results.jls")

release_script = joinpath(worktree_dir, "_bench.jl")
write(release_script, """
using Pkg
Pkg.activate(; temp=true)
Pkg.develop(path=$(repr(worktree_dir)))
Pkg.add("BenchmarkTools")
Pkg.add("Serialization")

using BenchmarkTools, Serialization, XML

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5
BenchmarkTools.DEFAULT_PARAMETERS.samples = 10000

small_xml = read($(repr(SMALL_FILE)), String)
medium_xml = read($(repr(MEDIUM_FILE)), String)
results = Dict{String, BenchmarkTools.Trial}()

results["Parse (small)"] = @benchmark parse(\$small_xml, Node)

try
    SSNode = Node{SubString{String}}
    results["Parse (small, SS)"] = @benchmark parse(\$small_xml, SSNode)
    results["Parse (medium, SS)"] = @benchmark parse(\$medium_xml, SSNode)
catch
end

results["Parse (medium)"] = @benchmark parse(\$medium_xml, Node)

small_node = parse(small_xml, Node)
medium_node = parse(medium_xml, Node)
results["Write (small)"] = @benchmark XML.write(\$small_node)
results["Write (medium)"] = @benchmark XML.write(\$medium_node)
results["Read file (medium)"] = @benchmark read($(repr(MEDIUM_FILE)), Node)

function _collect_tags!(out, node)
    for c in XML.children(node)
        if XML.nodetype(c) === XML.Element
            push!(out, XML.tag(c))
            _collect_tags!(out, c)
        end
    end
end
function bench_collect_tags(node)
    out = String[]
    _collect_tags!(out, node)
    out
end
results["Collect tags (small)"] = @benchmark bench_collect_tags(\$small_node)
results["Collect tags (medium)"] = @benchmark bench_collect_tags(\$medium_node)

try
    lazy_small = parse(small_xml, LazyNode)
    lazy_medium = parse(medium_xml, LazyNode)
    results["Parse (small), LazyNode"] = @benchmark parse(\$small_xml, LazyNode)
    results["Parse (medium), LazyNode"] = @benchmark parse(\$medium_xml, LazyNode)
catch
end

serialize($(repr(release_results_file)), results)
""")

print("Running $RELEASE_TAG benchmarks...")
flush(stdout)
run(pipeline(`julia $release_script`, stdout=devnull, stderr=devnull))
release_results = deserialize(release_results_file)
println(" done")

# Cleanup worktree
run(pipeline(`git -C $ROOT worktree remove --force $worktree_dir`, stdout=devnull, stderr=devnull))

#-----------------------------------------------------------------------------# Write compare_results.md
_fmt_ms(t) = string(round(t, sigdigits=3), " ms")

function _compare_indicator(dev_ms, rel_ms)
    change = (dev_ms / rel_ms - 1) * 100
    pct = abs(round(change, digits=1))
    change < -5 ? "($(pct)% faster)" : change > 5 ? "($(pct)% slower)" : "(~same)"
end

groups = [
    ("Parse (small)",        "Parse (small)",        ["Parse (small), String", "Parse (small), SubString", "Parse (small), LazyNode"]),
    ("Parse (medium)",       "Parse (medium)",       ["Parse (medium), String", "Parse (medium), SubString", "Parse (medium), LazyNode"]),
    ("Write (small)",        "Write (small)",        ["Write (small)", "Write (small), LazyNode"]),
    ("Write (medium)",       "Write (medium)",       ["Write (medium)", "Write (medium), LazyNode"]),
    ("Read file (medium)",   "Read file (medium)",   ["Read file (medium), String", "Read file (medium), SubString"]),
    ("Collect tags (small)", "Collect tags (small)",  ["Collect tags (small), String", "Collect tags (small), SubString"]),
    ("Collect tags (medium)","Collect tags (medium)", ["Collect tags (medium), String", "Collect tags (medium), SubString"]),
    ("sourcetext",           nothing,                 ["sourcetext, small", "sourcetext, medium"]),
    ("children vs eachchildnode (medium)", nothing,   ["children vs eachchildnode, children", "children vs eachchildnode, eachchildnode"]),
    ("SST-like: parse+iterate+write (10k)", nothing,  ["SST (parse+iterate+write), Node", "SST (parse+iterate+write), LazyNode+children", "SST (parse+iterate+write), LazyNode+eachchildnode"]),
]

outfile = joinpath(@__DIR__, "compare_results.md")
open(outfile, "w") do io
    println(io, "# XML.jl Benchmark Comparison: dev vs $RELEASE_TAG\n")
    println(io, "```")
    for (title, rel_key, dev_keys) in groups
        rel_ms = (!isnothing(rel_key) && haskey(release_results, rel_key)) ? median(release_results[rel_key]).time / 1e6 : nothing
        any(k -> haskey(dev_results, k), dev_keys) || (isnothing(rel_ms) && continue)

        println(io, title)
        if !isnothing(rel_ms)
            println(io, "\t", rpad(RELEASE_TAG, 16), lpad(_fmt_ms(rel_ms), 12))
        end
        for dk in dev_keys
            haskey(dev_results, dk) || continue
            dev_ms = median(dev_results[dk]).time / 1e6
            label = occursin(", ", dk) ? split(dk, ", "; limit=2)[2] : "dev"
            ms_str = lpad(_fmt_ms(dev_ms), 12)
            padlen = max(16, length(label) + 2)
            if isnothing(rel_ms)
                println(io, "\t", rpad(label, padlen), ms_str)
            else
                println(io, "\t", rpad(label, padlen), ms_str, "  ", _compare_indicator(dev_ms, rel_ms))
            end
        end
        println(io)
    end
    println(io, "```")

    println(io, "\n```julia")
    println(io, "versioninfo()")
    buf = IOBuffer()
    InteractiveUtils.versioninfo(buf)
    for line in eachline(IOBuffer(take!(buf)))
        println(io, "# ", line)
    end
    println(io, "```")
end

println("Results written to $outfile")
