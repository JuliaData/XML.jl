# benchmarks/profile_vs_039.jl
#
# Supplies the v0.3.9 column for profile.jl's DOM tables. PERFORMANCE-v0.4.md is a
# snapshot of v0.4 against v0.3.9 — the 0.3 → 0.4 story — so the tag is PINNED to
# v0.3.9 below; bump it deliberately if the document's story ever changes. Builds a temp
# git worktree at that tag and runs the SAME parse + full-extraction traversal under it
# in a clean subprocess (separate temp env), so dev vs v0.3.9 is apples-to-apples for
# the DOM. 0.3.x has no `Cursor`, so streaming has no direct 0.3.x analog and is omitted.
#
#   julia --project=benchmarks benchmarks/profile_vs_039.jl

using BenchmarkTools, Serialization, Statistics

const ROOT = dirname(@__DIR__)
const FILE = joinpath(@__DIR__, "data", "xmark.xml")
isfile(FILE) || error("generate xmark.xml first (run benchmarks.jl or profile.jl)")

const TAG = "v0.3.9"  # the document's comparison point — pinned, not "latest"
TAG in readlines(`git -C $ROOT tag`) ||
    error("tag $TAG not found locally; `git fetch --tags` first")
println("dev profile vs $TAG  (worktree + subprocess) ...")

wt      = mktempdir()
resfile = joinpath(wt, "_res.jls")
logfile = joinpath(wt, "_log.txt")
script  = joinpath(wt, "_b.jl")

run(pipeline(`git -C $ROOT worktree add $wt $TAG`, stdout = devnull, stderr = devnull))

# Subprocess: same traversal as profile.jl (touch tag + value on every node), under the tag.
write(script, """
using Pkg
Pkg.activate(; temp = true)
Pkg.develop(path = $(repr(wt)))
Pkg.add("BenchmarkTools"); Pkg.add("Serialization")
using BenchmarkTools, Serialization, XML
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5
const S = read($(repr(FILE)), String)

function walk(n)
    cnt = 1; acc = 0
    t = XML.tag(n);   t === nothing || (acc += sizeof(t))
    v = XML.value(n); v === nothing || (acc += sizeof(v))
    ch = XML.children(n)
    if ch !== nothing
        for c in ch
            c2, a2 = walk(c); cnt += c2; acc += a2
        end
    end
    (cnt, acc)
end

res = Dict{String,Any}()
res["nodes"]   = walk(parse(S, Node))[1]
res["parse"]   = @benchmark parse(\$S, Node)
res["extract"] = @benchmark walk(parse(\$S, Node))
serialize($(repr(resfile)), res)
""")

ok = success(pipeline(`julia $script`, stdout = logfile, stderr = logfile))
if !ok || !isfile(resfile)
    println("SUBPROCESS FAILED — log tail:\n", join(last(readlines(logfile), 30), "\n"))
    run(pipeline(`git -C $ROOT worktree remove --force $wt`, stdout = devnull, stderr = devnull))
    error("v$TAG subprocess did not complete")
end
res = deserialize(resfile)
run(pipeline(`git -C $ROOT worktree remove --force $wt`, stdout = devnull, stderr = devnull))

m(b)  = round(median(b).time / 1e6, digits = 2)
mb(b) = round(b.memory / 2^20, digits = 1)
println("\n=== $TAG — the v0.3.9 column (DOM tables) ===")
println("  nodes walked:     ", res["nodes"],
        "   (v0.4 walks 882026; v0.4 preserves whitespace Text nodes, 0.3.x dropped them)")
println("  parse → DOM:      ", m(res["parse"]),   " ms / ", mb(res["parse"]),   " MiB")
println("  full extraction:  ", m(res["extract"]), " ms / ", mb(res["extract"]), " MiB")
