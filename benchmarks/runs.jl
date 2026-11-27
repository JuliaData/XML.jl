# benchmarks/runs.jl
#
# Runs scripts of this folder several times, each time in a fresh process, and keeps what
# each run prints. Without a job, it runs the scripts of the published tables.
#
#   julia --project=benchmarks benchmarks/runs.jl [--runs=4] [job ...]
#
#   julia --project=benchmarks benchmarks/runs.jl
#   julia --project=benchmarks benchmarks/runs.jl profile.jl
#   julia --project=benchmarks benchmarks/runs.jl --runs=8 benchmarks.jl \
#       "--gcthreads=4 flatnode_bench.jl --gc-only"
#
# A job is one argument: a script, with the options of `julia` before it and its own
# arguments after it, separated by spaces. The options given to this launcher do not all
# reach the runs: a job names the ones its runs need.
#
# The runs go in passes: a pass runs each job once, in the order given. The runs of a job
# are then spread over the session. Started one after the other, they could all meet the
# same busy moment of the machine.
#
# When a process starts, the size of its environment sets the address of its stack, and a
# timing can change with that address: processes started alike measure one address again
# and again. An environment variable that nothing reads, `BENCH_PAD`, grows by 16 bytes
# from one pass to the next, so that each run of a job starts at another address.
#
# Each call writes to a new folder, `runs/<date>_<time>/`. What a job prints in pass i goes
# to `<name>_<i>.txt`, the name being the script followed by its arguments and options. A
# results file of this folder that the script rewrites, as `benchmarks.jl` does with
# `benchmarks_results.md`, is moved beside it under the same prefix, and the file it
# replaced is put back.

const DIR = @__DIR__
const USAGE = "usage: runs.jl [--runs=4] [\"[options of julia] script [arguments]\" ...]"

# The jobs behind the published tables.
const TABLES = ["benchmarks.jl", "profile.jl", "flatnode_bench.jl",
                "flatnode_bench.jl --gc-only", "--gcthreads=4 flatnode_bench.jl --gc-only",
                "profile_vs_039.jl"]

fail(message) = (flush(stdout); println(stderr, message); exit(1))

# A job from its text: the options of `julia`, the script, its arguments, and the name that
# starts its files.
function read_job(text)
    words = String.(split(text))
    at = findfirst(w -> !startswith(w, "-"), words)
    at === nothing && fail("no script in the job \"$text\"\n$USAGE")
    script = joinpath(DIR, words[at])
    isfile(script) || fail("no script $(words[at])\n$USAGE")
    options, arguments = words[1:at-1], words[at+1:end]
    parts = [first(splitext(basename(script))); arguments; options]
    name = join((replace(lstrip(p, '-'), r"[^\w.=-]" => "-") for p in parts), "_")
    ncodeunits(name) <= 200 || fail("the job \"$text\" makes too long a file name")
    (; text, name, options, script, arguments)
end

isruns(a) = startswith(a, "--runs=")
const RUNS = let given = filter(isruns, ARGS)
    isempty(given) ? 4 : something(tryparse(Int, last(given)[8:end]), 0)
end
RUNS >= 1 || fail(USAGE)
const JOBS = let texts = filter(!isruns, ARGS)
    map(read_job, isempty(texts) ? TABLES : texts)
end
allunique(j.name for j in JOBS) || fail("two jobs would write to the same files")
const OUT = joinpath(DIR, "runs", Libc.strftime("%Y-%m-%d_%H%M%S", time()))

# The results files of this folder (`*_results.*`), each with its content.
results() = Dict(f => read(joinpath(DIR, f)) for f in readdir(DIR)
                 if occursin("_results.", f) && isfile(joinpath(DIR, f)))

# Moves to the output folder, under `prefix`, each results file written since `before`, and
# puts back what it replaced.
function keep_written(before, prefix)
    for (f, content) in results()
        get(before, f, nothing) == content && continue
        mv(joinpath(DIR, f), joinpath(OUT, string(prefix, "_", f)); force = true)
    end
    for (f, content) in before
        isfile(joinpath(DIR, f)) || write(joinpath(DIR, f), content)
    end
end

# The run under way: what an interrupted launcher still has to put back.
const PENDING = Ref{Any}(nothing)
atexit(() -> PENDING[] === nothing || keep_written(PENDING[]...))

# Runs `job` once, with all it prints sent to `file`, and returns whether it succeeded and
# its duration in seconds. `prefix` starts the names of the files kept from this run.
function measure(job, pass, prefix, file)
    project = dirname(Base.active_project())
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project
           $(job.options) $(job.script) $(job.arguments)`
    cmd = addenv(ignorestatus(cmd), "BENCH_PAD" => "x"^(16 * (pass - 1)))
    PENDING[] = (results(), prefix)
    start = time()
    process = open(io -> run(pipeline(cmd; stdout = io, stderr = io)), file, "w")
    seconds = time() - start
    keep_written(PENDING[]...)
    PENDING[] = nothing
    success(process), seconds
end

mkpath(OUT)
println(length(JOBS), " job(s), ", RUNS, " pass(es), outputs in ", relpath(OUT))
failed = String[]
for pass in 1:RUNS, job in JOBS
    prefix = string(job.name, "_", pass)
    file = joinpath(OUT, prefix * ".txt")
    print(Libc.strftime("%H:%M:%S", time()), "  pass ", pass, " of ", RUNS, "  ", job.text,
          ": ")
    flush(stdout)
    ok, seconds = measure(job, pass, prefix, file)
    println(round(Int, seconds), " s", ok ? "" : ", failed: see " * relpath(file))
    ok || push!(failed, relpath(file))
end
isempty(failed) || fail("failed: " * join(failed, ", "))
