# XML.jl Benchmarks

```
Parse (small)
	XML.jl              0.013 ms
	XML.jl (SS)        0.0119 ms
	EzXML              0.0113 ms  (XML.jl 15.5% slower)
	LightXML           0.0111 ms  (XML.jl 17.7% slower)
	XMLDict             0.115 ms  (XML.jl 88.7% faster)

Parse (medium)
	XML.jl               68.8 ms
	XML.jl (SS)          61.3 ms
	EzXML                39.7 ms  (XML.jl 73.3% slower)
	LightXML             37.3 ms  (XML.jl 84.4% slower)
	XMLDict             349.0 ms  (XML.jl 80.3% faster)

Write (small)
	XML.jl            0.00589 ms
	EzXML             0.00586 ms  (~same)
	LightXML           0.0642 ms  (XML.jl 90.8% faster)

Write (medium)
	XML.jl               24.9 ms
	EzXML                21.6 ms  (XML.jl 15.3% slower)
	LightXML             32.1 ms  (XML.jl 22.3% faster)

Read file
	XML.jl               69.8 ms
	EzXML                40.0 ms  (XML.jl 74.3% slower)
	LightXML             39.1 ms  (XML.jl 78.3% slower)

Collect tags (small)
	XML.jl           0.000371 ms
	EzXML             0.00107 ms  (XML.jl 65.2% faster)
	LightXML           0.0018 ms  (XML.jl 79.4% faster)

Collect tags (medium)
	XML.jl               4.76 ms
	EzXML                10.7 ms  (XML.jl 55.7% faster)
	LightXML             16.4 ms  (XML.jl 71.0% faster)

Parse SST (LazyNode)
	XML.jl             0.0656 ms
	Node (for ref)       13.7 ms  (XML.jl 99.5% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0389 ms
	Node (for ref)       27.0 ms  (XML.jl 99.9% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     24.0 ms
	LazyNode + write (normalize)     64.8 ms
	Node (for ref)       6.99 ms

SST: unformatted text
	LazyNode + is_simple_value     23.9 ms
	Node (for ref)        3.1 ms

Worksheet: collect rows
	children() (fresh Vector each call)     25.4 ms
	children!(buf, n) (reused buffer)     26.5 ms

Worksheet: attribute scan
	eachattribute        22.5 ms
	attributes() (materialize dict)     23.1 ms

Worksheet: single attr fetch
	get(c, "r", "")      23.2 ms
	attributes(c)["r"]     22.3 ms

Worksheet: <v> value
	is_simple_value      24.1 ms
	is_simple + simple_value     24.1 ms

XLSX sst_load! (end-to-end)
	LazyNode             29.3 ms
	LazyNode (entity-heavy)     27.2 ms

XLSX cell read (end-to-end)
	numeric ws           22.7 ms
	string ws            20.5 ms

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
