# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0216 ms
	XML.jl (SS)        0.0196 ms
	EzXML              0.0136 ms  (XML.jl 58.9% slower)
	LightXML           0.0112 ms  (XML.jl 91.8% slower)
	XMLDict             0.112 ms  (XML.jl 80.7% faster)

Parse (medium)
	XML.jl              115.0 ms
	XML.jl (SS)         107.0 ms
	EzXML                47.2 ms  (XML.jl 143.3% slower)
	LightXML             47.5 ms  (XML.jl 141.8% slower)
	XMLDict             352.0 ms  (XML.jl 67.3% faster)

Write (small)
	XML.jl            0.00572 ms
	EzXML             0.00574 ms  (~same)
	LightXML           0.0573 ms  (XML.jl 90.0% faster)

Write (medium)
	XML.jl               28.3 ms
	EzXML                21.1 ms  (XML.jl 34.3% slower)
	LightXML             30.3 ms  (XML.jl 6.5% faster)

Read file
	XML.jl              110.0 ms
	EzXML                60.0 ms  (XML.jl 83.6% slower)
	LightXML             70.2 ms  (XML.jl 56.9% slower)

Collect tags (small)
	XML.jl           0.000371 ms
	EzXML             0.00109 ms  (XML.jl 65.8% faster)
	LightXML           0.0018 ms  (XML.jl 79.4% faster)

Collect tags (medium)
	XML.jl               5.63 ms
	EzXML                10.6 ms  (XML.jl 46.7% faster)
	LightXML             12.7 ms  (XML.jl 55.5% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       17.1 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       28.5 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     33.6 ms
	LazyNode + write (normalize)     71.7 ms
	Node (for ref)       5.58 ms

SST: unformatted text
	LazyNode + is_simple_value     39.3 ms
	Node (for ref)       2.39 ms

Worksheet: collect rows
	children() (fresh Vector each call)     36.6 ms
	children!(buf, n) (reused buffer)     36.4 ms

Worksheet: attribute scan
	eachattribute        36.3 ms
	attributes() (materialize dict)     36.5 ms

Worksheet: single attr fetch
	get(c, "r", "")      36.7 ms
	attributes(c)["r"]     36.2 ms

Worksheet: <v> value
	is_simple_value      36.6 ms
	is_simple + simple_value     36.5 ms

XLSX sst_load! (end-to-end)
	LazyNode             53.3 ms
	LazyNode (entity-heavy)     47.4 ms

XLSX cell read (end-to-end)
	numeric ws           36.6 ms
	string ws            33.6 ms

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
