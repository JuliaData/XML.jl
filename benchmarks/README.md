# Benchmarks

The scripts of this folder measure XML.jl with BenchmarkTools. They run in the environment of the folder, which takes XML.jl from the working tree:

```sh
julia --project=benchmarks -e 'using Pkg; Pkg.instantiate()'
```

Julia 1.10 does not read the `[sources]` section that names the working tree, and would install the registered release: under it, name the tree first.

```sh
julia --project=benchmarks -e 'using Pkg; Pkg.develop(path = "."); Pkg.instantiate()'
```

| Script | What it measures |
|---|---|
| `benchmarks.jl` | the benchmark table of the README, against EzXML, LightXML and XMLDict |
| `profile.jl` | Tables 1 to 4, 6 and 7 of `PERFORMANCE-v0.4.md`, and its memory-mapped table |
| `profile_vs_039.jl` | the v0.3.9 row of Table 2 |
| `flatnode_bench.jl` | Tables 5 and 8 of that page, and the access-pattern table of the README |
| `dict_benchmarks.jl` | `Attributes`, the type that `attributes` returns, against a `Dict`, for 2 to 20 attributes |
| `compare.jl` | two versions of XML.jl, one against the other |
| `runs.jl` | the scripts above several times, each time in a fresh process |

## A timing depends on the process that measures it

When a process starts, the size of its environment and of its command line sets the address of its stack, and a timing can change with that address. Mytkowicz, Diwan, Hauswirth and Sweeney describe the effect in [Producing Wrong Data Without Doing Anything Obviously Wrong!](https://doi.org/10.1145/1508244.1508275) (ASPLOS 2009). One process can also be slower than the next on every cell it measures.

Two versions measured by two scripts, under two labels or from two directories start at two addresses, and the gap between them can be that of the addresses. Processes started alike measure one address again and again.

`compare.jl` and `runs.jl` therefore measure in several fresh processes, and give each one another address: an environment variable that nothing reads, `BENCH_PAD`, grows by 16 bytes from one run to the next. The spread between the runs shows how far a timing moves from one process to the next, and a difference counts only beyond that spread.

## Comparing two versions

```sh
julia --project=benchmarks benchmarks/compare.jl v0.4.10 main
```

Each argument is a revision of the repository or a directory that holds a copy of the package. Without arguments, the latest release tag is compared with the working tree. A version is loaded from a copy of its sources alone, so one that depends on a package outside the standard library, as the 0.3 releases do, cannot be measured.

Every measure runs in a fresh process, by the same script and the same command line, on a copy of the version put in one directory. The two versions take turns. Each cell shows the ratio of the medians of the runs. Where the runs of the two versions overlap, where their medians stand less than 5 % apart, or with fewer than three runs of each, the cell says that nothing is established.

`compare_cells.jl` holds the cells. To measure others, copy it in this folder, change its list, and pass the copy with `--cells=`.

## Measuring the published tables again

```sh
julia --project=benchmarks benchmarks/runs.jl
```

`runs.jl` runs each script of the published tables four times, and writes what each run prints to a new folder under `benchmarks/runs/`. The published figures are the medians of these four runs.

The runs go in passes: a pass runs every script once. The runs of a script are then spread over the session. Started one after the other, they could all meet the same busy moment of the machine.

A results file of this folder that a script rewrites, as `benchmarks.jl` does with `benchmarks_results.md`, is moved to that folder too, and the file of the repository is put back.

To run other jobs, name them:

```sh
julia --project=benchmarks benchmarks/runs.jl --runs=8 profile.jl "--gcthreads=4 flatnode_bench.jl --gc-only"
```

A job is one argument: a script, with the options of `julia` before it and its own arguments after it. The options given to `runs.jl` itself do not all reach the runs.
