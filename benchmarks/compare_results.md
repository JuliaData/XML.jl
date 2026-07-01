# XML.jl Benchmark Comparison: dev vs v0.3.8

```
Parse (small)
	v0.3.8              0.139 ms
	String             0.0409 ms  (70.6% faster)
	SubString           0.033 ms  (76.3% faster)
	LazyNode          6.33e-6 ms  (100.0% faster)

Parse (medium)
	v0.3.8              829.0 ms
	String              200.0 ms  (75.8% faster)
	SubString           163.0 ms  (80.4% faster)
	LazyNode          6.33e-6 ms  (100.0% faster)

Write (small)
	v0.3.8              0.032 ms
	dev                0.0215 ms  (32.6% faster)
	LazyNode         0.000217 ms  (99.3% faster)

Write (medium)
	v0.3.8              156.0 ms
	dev                  99.2 ms  (36.3% faster)
	LazyNode         0.000273 ms  (100.0% faster)

Read file (medium)
	v0.3.8              755.0 ms
	String              193.0 ms  (74.4% faster)
	SubString           179.0 ms  (76.3% faster)

Collect tags (small)
	v0.3.8            0.00064 ms
	String           0.000714 ms  (11.7% slower)
	SubString         0.00211 ms  (230.3% slower)

Collect tags (medium)
	v0.3.8               21.6 ms
	String               13.3 ms  (38.7% faster)
	SubString            20.3 ms  (6.2% faster)

sourcetext
	small            0.000191 ms
	medium           0.000248 ms

children vs eachchildnode (medium)
	children             76.8 ms
	eachchildnode        80.4 ms

SST-like: parse+iterate+write (10k)
	Node                 9.01 ms
	LazyNode+children       9.78 ms
	LazyNode+eachchildnode       10.4 ms

```

```julia
versioninfo()
# Julia Version 1.12.6
# Commit 15346901f00 (2026-04-09 19:20 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin24.0.0)
#   CPU: 10 × Apple M1 Pro
#   WORD_SIZE: 64
#   LLVM: libLLVM-18.1.7 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 8 default, 1 interactive, 8 GC (on 8 virtual cores)
# Environment:
#   JULIA_NUM_THREADS = auto
```
