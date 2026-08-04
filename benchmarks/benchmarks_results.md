# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0132 ms
	XML.jl (SS)        0.0123 ms
	EzXML              0.0126 ms  (~same)
	LightXML           0.0118 ms  (XML.jl 12.4% slower)
	XMLDict             0.111 ms  (XML.jl 88.1% faster)

Parse (medium)
	XML.jl               70.0 ms
	XML.jl (SS)          69.6 ms
	EzXML                46.3 ms  (XML.jl 51.1% slower)
	LightXML             36.8 ms  (XML.jl 90.1% slower)
	XMLDict             353.0 ms  (XML.jl 80.2% faster)

Write (small)
	XML.jl            0.00559 ms
	EzXML             0.00578 ms  (~same)
	LightXML           0.0576 ms  (XML.jl 90.3% faster)

Write (medium)
	XML.jl               24.5 ms
	EzXML                21.3 ms  (XML.jl 14.7% slower)
	LightXML             30.1 ms  (XML.jl 18.7% faster)

Read file
	XML.jl               73.1 ms
	EzXML                58.6 ms  (XML.jl 24.6% slower)
	LightXML             39.6 ms  (XML.jl 84.7% slower)

Collect tags (small)
	XML.jl            0.00037 ms
	EzXML             0.00115 ms  (XML.jl 68.0% faster)
	LightXML          0.00185 ms  (XML.jl 80.0% faster)

Collect tags (medium)
	XML.jl               4.79 ms
	EzXML                10.5 ms  (XML.jl 54.3% faster)
	LightXML             13.4 ms  (XML.jl 64.2% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       10.0 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       17.9 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     21.4 ms
	LazyNode + write (normalize)     52.3 ms
	Node (for ref)       5.58 ms

SST: unformatted text
	LazyNode + is_simple_value     23.7 ms
	Node (for ref)        2.4 ms

Worksheet: collect rows
	children() (fresh Vector each call)     22.8 ms
	children!(buf, n) (reused buffer)     22.9 ms

Worksheet: attribute scan
	eachattribute        22.7 ms
	attributes() (materialize dict)     22.7 ms

Worksheet: single attr fetch
	get(c, "r", "")      22.7 ms
	attributes(c)["r"]     22.9 ms

Worksheet: <v> value
	is_simple_value      22.7 ms
	is_simple + simple_value     22.9 ms

XLSX sst_load! (end-to-end)
	LazyNode             31.7 ms
	LazyNode (entity-heavy)     32.3 ms

XLSX cell read (end-to-end)
	numeric ws           22.7 ms
	string ws            20.7 ms

```

```julia
versioninfo()
# Julia Version 1.12.6
# Commit 15346901f00 (2026-04-09 19:20 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin24.0.0)
#   CPU: 10 × Apple M5
#   WORD_SIZE: 64
#   LLVM: libLLVM-18.1.7 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 1 default, 1 interactive, 1 GC (on 4 virtual cores)
```
