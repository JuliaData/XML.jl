# benchmarks/profile_vs_039.jl
#
# Supplies the v0.3.9 column for profile.jl's DOM regimes. Builds a temp git worktree at
# the latest release tag and runs the SAME parse + full-walk extraction under 0.3.9 in a
# clean subprocess (separate temp env), so v0.4 vs 0.3.9 is apples-to-apples for the DOM.
# 0.3.x has no `Cursor`, so the STREAM regime has no direct 0.3.x analog and is omitted.
#
#   julia --project=benchmarks benchmarks/profile_vs_039.jl

using BenchmarkTools, Serialization, Statistics

const ROOT = dirname(@__DIR__)
const FILE = joinpath(@__DIR__, "data", "xmark.xml")
isfile(FILE) || error("generate xmark.xml first (run benchmarks.jl or profile.jl)")

const TAG = let tags = filter(t -> startswith(t, "v"),
                              readlines(`git -C $ROOT tag --sort=version:refname`))
    isempty(tags) && error("no vX.Y.Z release tag found locally; `git fetch --tags` first")
    last(tags)
end
println("dev profile vs $TAG  (worktree + subprocess) ...")

wt      = mktempdir()
resfile = joinpath(wt, "_res.jls")
logfile = joinpath(wt, "_log.txt")
script  = joinpath(wt, "_b.jl")

run(pipeline(`git -C $ROOT worktree add $wt $TAG`, stdout = devnull, stderr = devnull))

# Subprocess: same walk as profile.jl (touch tag + value on every node), under 0.3.9.
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
println("\n=== v$TAG — the v0.3.9 column (DOM regimes) ===")
println("  nodes walked:     ", res["nodes"],
        "   (v0.4 walks 882026; v0.4 preserves whitespace Text nodes, 0.3.x dropped them)")
println("  parse → DOM:      ", m(res["parse"]),   " ms / ", mb(res["parse"]),   " MiB")
println("  full extraction:  ", m(res["extract"]), " ms / ", mb(res["extract"]), " MiB")
