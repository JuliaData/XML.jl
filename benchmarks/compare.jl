# benchmarks/compare.jl
#
# Compares two versions of XML.jl, cell by cell.
#
#   julia --project=benchmarks benchmarks/compare.jl [before [after]]
#                                                    [--runs=4] [--rounds=3] [--cells=FILE]
#
# `before` and `after` are each a revision of this repository (a tag, a branch, a commit)
# or a directory that holds a copy of the package. `before` defaults to the latest release
# tag, `after` to the working tree. Each one is loaded from a copy of its sources alone: a
# version that depends on a package outside the standard library, as the 0.3 releases do,
# cannot be measured.
#
# When a process starts, the size of its environment and of its command line sets the
# address of its stack, and a timing can change with that address. Two versions measured by
# two scripts, under two labels or from two directories start at two addresses, and the gap
# between them can be that of the addresses. So here:
#   - every measure runs in a fresh process, by the same script (`compare_cells.jl`), with
#     the same command line;
#   - the version under measure is copied into one directory, the same for both;
#   - an environment variable that nothing reads, `BENCH_PAD`, grows by 16 bytes from one
#     run to the next, so that each run starts at another address;
#   - the two versions take turns, in an order that alternates, so that a drift of the
#     machine falls on both.
# A cell then shows the ratio of the two medians. Nothing is established where the runs of
# the two versions overlap, where their medians stand less than 5 % apart, or with fewer
# than three runs of each: one process can be slower than the next on every cell.

using Statistics

const ROOT = dirname(@__DIR__)
const USAGE = "usage: compare.jl [before [after]] [--runs=N] [--rounds=N] [--cells=FILE]"
const LEAST_RUNS = 3

fail(message) = (println(stderr, message); exit(1))

function options(args)
    versions = String[]
    opt = Dict("runs" => "4", "rounds" => "3",
               "cells" => joinpath(@__DIR__, "compare_cells.jl"))
    for a in args
        m = match(r"^--(runs|rounds|cells)=(.+)$", a)
        if m !== nothing
            opt[m[1]] = m[2]
        elseif startswith(a, "--")
            fail("unknown option $a\n$USAGE")
        else
            push!(versions, a)
        end
    end
    length(versions) <= 2 || fail(USAGE)
    all(k -> something(tryparse(Int, opt[k]), 0) >= 1, ("runs", "rounds")) || fail(USAGE)
    return versions, opt
end

function latest_tag()
    tags = filter(startswith("v"), readlines(`git -C $ROOT tag --sort=version:refname`))
    isempty(tags) && fail("no release tag in this repository: name the two versions")
    return last(tags)
end

# The package of a version: its project file, its sources and its extensions.
const PACKAGE = ("Project.toml", "src", "ext")

function copy_package(from, to)
    mkpath(to)
    for item in PACKAGE
        ispath(joinpath(from, item)) && cp(joinpath(from, item), joinpath(to, item))
    end
end

# Puts the version `spec` in `dir`, and returns how to name it. A revision goes through
# `git archive`, which leaves the working tree as it is.
function export_version(spec, dir)
    if isdir(spec)
        isfile(joinpath(spec, "Project.toml")) && isdir(joinpath(spec, "src")) ||
            fail("no package in the directory $spec")
        copy_package(spec, dir)
        return samefile(spec, ROOT) ? "the working tree" : "the directory $(abspath(spec))"
    end
    out = IOBuffer()
    commit = `git -C $ROOT rev-parse --verify --quiet $(spec * "^{commit}")`
    success(pipeline(commit; stdout = out, stderr = devnull)) ||
        fail("`$spec` is neither a directory nor a revision of this repository")
    sha = strip(String(take!(out)))
    whole = mktempdir()
    run(pipeline(`git -C $ROOT archive --format=tar $sha`, `tar -x -C $whole`))
    copy_package(whole, dir)
    return string(spec, " (", first(sha, 7), ")")
end

# One run of the cells, in a fresh process that loads the package from `tree`. The other
# packages come from the environment this script runs in. Returns `nothing` if the process
# fails; what it wrote on its error stream has then been shown.
function measure(tree, cells, rounds, pad)
    environment = dirname(Base.active_project())
    path = join((tree, environment, "@stdlib"), Sys.iswindows() ? ';' : ':')
    cmd = `$(Base.julia_cmd()) --startup-file=no $cells $rounds`
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => path, "BENCH_PAD" => pad)
    out = IOBuffer()
    success(pipeline(cmd; stdout = out, stderr = stderr)) || return nothing
    lines = (split(line, '\t') for line in eachline(seekstart(out)))
    return [(String(l[1]), parse(Float64, l[2])) for l in lines if length(l) == 2]
end

two(x) = (r = round(x; sigdigits = 2); r >= 10 ? string(round(Int, r)) : string(r))

# The runs of one version: their median, then the lowest and the highest, in the unit
# that fits the median once it is rounded.
function runs_string(t)
    any(isnan, t) && return "n/a"
    r = round(median(t); sigdigits = 2)
    scale, unit = r >= 1e9 ? (1e9, "s") : r >= 1e6 ? (1e6, "ms") :
                  r >= 1e3 ? (1e3, "µs") : (1.0, "ns")
    return string(two(r / scale), " ", unit, " (", two(minimum(t) / scale), " to ",
                  two(maximum(t) / scale), ")")
end

function verdict(before, after)
    (any(isnan, before) || any(isnan, after)) && return "n/a"
    min(length(before), length(after)) >= LEAST_RUNS || return "not established"
    ratio = median(after) / median(before)
    overlap = minimum(after) <= maximum(before) && minimum(before) <= maximum(after)
    return overlap || abs(ratio - 1) < 0.05 ? "not established" : string(two(ratio), "×")
end

function main(args)
    versions, opt = options(args)
    before = length(versions) >= 1 ? versions[1] : latest_tag()
    after = length(versions) >= 2 ? versions[2] : ROOT
    runs, rounds, cells = parse(Int, opt["runs"]), opt["rounds"], abspath(opt["cells"])
    isfile(cells) || fail("no file $cells")
    work = mktempdir()
    dirs = (joinpath(work, "before"), joinpath(work, "after"))
    tree = joinpath(work, "tree")
    labels = (export_version(before, dirs[1]), export_version(after, dirs[2]))
    println("before: ", labels[1])
    println("after:  ", labels[2])
    println("julia ", VERSION, "; ", runs, runs == 1 ? " run" : " runs",
            " of each version, in turns")
    names = String[]
    times = (Dict{String,Vector{Float64}}(), Dict{String,Vector{Float64}}())
    for i in 1:runs, v in (isodd(i) ? (1, 2) : (2, 1))
        rm(tree; recursive = true, force = true)
        copy_package(dirs[v], tree)
        local run_times
        t = @elapsed run_times = measure(tree, cells, rounds, "x"^(16 * (i - 1)))
        run_times === nothing && fail("the cells did not run on $(labels[v])")
        for (name, ns) in run_times
            name in names || push!(names, name)
            push!(get!(times[v], name, Float64[]), ns)
        end
        println("  run ", i, " of ", runs, ", ", ("before", "after")[v], ": ",
                round(Int, t), " s")
    end
    of(v, name) = get(times[v], name, [NaN])
    rows = [(n, runs_string(of(1, n)), runs_string(of(2, n)), verdict(of(1, n), of(2, n)))
            for n in names]
    pushfirst!(rows, ("", "before", "after", "after / before"))
    width = [maximum(textwidth(r[k]) for r in rows) for k in 1:3]
    println()
    for r in rows
        println(join((rpad(r[k], width[k]) for k in 1:3), "  "), "  ", r[4])
    end
    println("\nEach version: the median of its runs, then the lowest and the highest.")
    runs >= LEAST_RUNS || println("Fewer than ", LEAST_RUNS,
                                  " runs of each version: nothing can be established.")
end

main(ARGS)
