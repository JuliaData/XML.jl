# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0378 ms
	XML.jl (SS)        0.0349 ms
	EzXML              0.0224 ms  (XML.jl 68.8% slower)
	LightXML            0.022 ms  (XML.jl 72.3% slower)
	XMLDict             0.209 ms  (XML.jl 81.9% faster)

Parse (medium)
	XML.jl              201.0 ms
	XML.jl (SS)         190.0 ms
	EzXML                80.3 ms  (XML.jl 150.7% slower)
	LightXML            114.0 ms  (XML.jl 76.1% slower)
	XMLDict             608.0 ms  (XML.jl 66.9% faster)

Write (small)
	XML.jl            0.00957 ms
	EzXML              0.0108 ms  (XML.jl 11.7% faster)
	LightXML            0.105 ms  (XML.jl 90.9% faster)

Write (medium)
	XML.jl               48.3 ms
	EzXML                36.9 ms  (XML.jl 30.9% slower)
	LightXML             56.2 ms  (XML.jl 14.1% faster)

Read file
	XML.jl              191.0 ms
	EzXML               115.0 ms  (XML.jl 67.2% slower)
	LightXML             97.4 ms  (XML.jl 96.6% slower)

Collect tags (small)
	XML.jl           0.000602 ms
	EzXML              0.0021 ms  (XML.jl 71.4% faster)
	LightXML          0.00381 ms  (XML.jl 84.2% faster)

Collect tags (medium)
	XML.jl               12.7 ms
	EzXML                16.3 ms  (XML.jl 21.8% faster)
	LightXML             23.5 ms  (XML.jl 45.9% faster)

Parse SST (LazyNode)
	XML.jl            5.29e-6 ms
	Node (for ref)       45.8 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            5.21e-6 ms
	Node (for ref)       69.6 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     93.0 ms
	LazyNode + write (normalize)    157.0 ms
	Node (for ref)       9.83 ms

SST: unformatted text
	LazyNode + is_simple_value    102.0 ms
	Node (for ref)       5.31 ms

Worksheet: collect rows
	children() (fresh Vector each call)     87.9 ms
	children!(buf, n) (reused buffer)     87.9 ms

Worksheet: attribute scan
	eachattribute        87.8 ms
	attributes() (materialize dict)     87.2 ms

Worksheet: single attr fetch
	get(c, "r", "")      87.6 ms
	attributes(c)["r"]     88.0 ms

Worksheet: <v> value
	is_simple_value      87.1 ms
	is_simple + simple_value     87.8 ms

XLSX sst_load! (end-to-end)
	LazyNode            149.0 ms
	LazyNode (entity-heavy)    113.0 ms

XLSX cell read (end-to-end)
	numeric ws           87.9 ms
	string ws            80.2 ms

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
