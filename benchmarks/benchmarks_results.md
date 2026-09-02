# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0132 ms
	XML.jl (SS)        0.0123 ms
	EzXML              0.0119 ms  (XML.jl 11.2% slower)
	LightXML           0.0117 ms  (XML.jl 12.8% slower)
	XMLDict             0.115 ms  (XML.jl 88.5% faster)

Parse (medium)
	XML.jl               69.9 ms
	XML.jl (SS)          61.9 ms
	EzXML                37.5 ms  (XML.jl 86.3% slower)
	LightXML             38.5 ms  (XML.jl 81.3% slower)
	XMLDict             354.0 ms  (XML.jl 80.2% faster)

Write (small)
	XML.jl            0.00601 ms
	EzXML             0.00566 ms  (XML.jl 6.3% slower)
	LightXML           0.0568 ms  (XML.jl 89.4% faster)

Write (medium)
	XML.jl               25.2 ms
	EzXML                21.7 ms  (XML.jl 16.5% slower)
	LightXML             29.8 ms  (XML.jl 15.3% faster)

Read file
	XML.jl               70.9 ms
	EzXML                39.8 ms  (XML.jl 78.5% slower)
	LightXML             39.7 ms  (XML.jl 78.9% slower)

Collect tags (small)
	XML.jl           0.000369 ms
	EzXML             0.00108 ms  (XML.jl 65.7% faster)
	LightXML           0.0018 ms  (XML.jl 79.5% faster)

Collect tags (medium)
	XML.jl               4.73 ms
	EzXML                10.6 ms  (XML.jl 55.3% faster)
	LightXML             13.7 ms  (XML.jl 65.5% faster)

Parse SST (LazyNode)
	XML.jl             0.0381 ms
	Node (for ref)       9.86 ms  (XML.jl 99.6% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0279 ms
	Node (for ref)       17.3 ms  (XML.jl 99.8% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     19.5 ms
	LazyNode + write (normalize)     50.5 ms
	Node (for ref)       5.89 ms

SST: unformatted text
	LazyNode + is_simple_value     19.6 ms
	Node (for ref)       2.28 ms

Worksheet: collect rows
	children() (fresh Vector each call)     22.7 ms
	children!(buf, n) (reused buffer)     22.7 ms

Worksheet: attribute scan
	eachattribute        22.4 ms
	attributes() (materialize dict)     22.3 ms

Worksheet: single attr fetch
	get(c, "r", "")      22.4 ms
	attributes(c)["r"]     22.3 ms

Worksheet: <v> value
	is_simple_value      22.3 ms
	is_simple + simple_value     22.4 ms

XLSX sst_load! (end-to-end)
	LazyNode             27.3 ms
	LazyNode (entity-heavy)     19.8 ms

XLSX cell read (end-to-end)
	numeric ws           22.4 ms
	string ws            20.4 ms

```

```julia
versioninfo()
# Julia Version 1.12.7
# Commit 6d172b025e4 (2026-08-15 08:05 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin25.5.0)
#   CPU: 10 × Apple M5
#   WORD_SIZE: 64
#   LLVM: libLLVM-18.1.7 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 1 default, 1 interactive, 1 GC (on 4 virtual cores)
```
