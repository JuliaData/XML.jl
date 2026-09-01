# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0129 ms
	XML.jl (SS)        0.0119 ms
	EzXML              0.0134 ms  (~same)
	LightXML           0.0113 ms  (XML.jl 14.0% slower)
	XMLDict             0.116 ms  (XML.jl 88.8% faster)

Parse (medium)
	XML.jl               67.7 ms
	XML.jl (SS)          67.8 ms
	EzXML                46.7 ms  (XML.jl 44.8% slower)
	LightXML             37.6 ms  (XML.jl 80.0% slower)
	XMLDict             369.0 ms  (XML.jl 81.7% faster)

Write (small)
	XML.jl            0.00601 ms
	EzXML             0.00562 ms  (XML.jl 6.9% slower)
	LightXML           0.0597 ms  (XML.jl 89.9% faster)

Write (medium)
	XML.jl               24.4 ms
	EzXML                20.8 ms  (XML.jl 17.5% slower)
	LightXML             29.2 ms  (XML.jl 16.4% faster)

Read file
	XML.jl               70.7 ms
	EzXML                59.9 ms  (XML.jl 18.1% slower)
	LightXML             39.1 ms  (XML.jl 80.8% slower)

Collect tags (small)
	XML.jl           0.000369 ms
	EzXML             0.00107 ms  (XML.jl 65.5% faster)
	LightXML          0.00182 ms  (XML.jl 79.7% faster)

Collect tags (medium)
	XML.jl                4.8 ms
	EzXML                10.5 ms  (XML.jl 54.2% faster)
	LightXML             13.1 ms  (XML.jl 63.4% faster)

Parse SST (LazyNode)
	XML.jl              0.038 ms
	Node (for ref)       9.87 ms  (XML.jl 99.6% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0279 ms
	Node (for ref)       17.3 ms  (XML.jl 99.8% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     19.4 ms
	LazyNode + write (normalize)     50.4 ms
	Node (for ref)       5.51 ms

SST: unformatted text
	LazyNode + is_simple_value     19.4 ms
	Node (for ref)       2.27 ms

Worksheet: collect rows
	children() (fresh Vector each call)     22.6 ms
	children!(buf, n) (reused buffer)     22.7 ms

Worksheet: attribute scan
	eachattribute        22.7 ms
	attributes() (materialize dict)     22.8 ms

Worksheet: single attr fetch
	get(c, "r", "")      22.8 ms
	attributes(c)["r"]     22.8 ms

Worksheet: <v> value
	is_simple_value      22.9 ms
	is_simple + simple_value     22.8 ms

XLSX sst_load! (end-to-end)
	LazyNode             27.1 ms
	LazyNode (entity-heavy)     27.5 ms

XLSX cell read (end-to-end)
	numeric ws           22.8 ms
	string ws            20.8 ms

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
