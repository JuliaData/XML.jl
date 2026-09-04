# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0129 ms
	XML.jl (SS)        0.0118 ms
	EzXML               0.012 ms  (XML.jl 8.0% slower)
	LightXML           0.0118 ms  (XML.jl 9.5% slower)
	XMLDict             0.114 ms  (XML.jl 88.6% faster)

Parse (medium)
	XML.jl               69.2 ms
	XML.jl (SS)          60.9 ms
	EzXML                37.1 ms  (XML.jl 86.3% slower)
	LightXML             37.8 ms  (XML.jl 82.9% slower)
	XMLDict             354.0 ms  (XML.jl 80.5% faster)

Write (small)
	XML.jl            0.00585 ms
	EzXML             0.00578 ms  (~same)
	LightXML           0.0588 ms  (XML.jl 90.0% faster)

Write (medium)
	XML.jl               25.4 ms
	EzXML                21.0 ms  (XML.jl 20.8% slower)
	LightXML             29.4 ms  (XML.jl 13.7% faster)

Read file
	XML.jl               68.9 ms
	EzXML                39.9 ms  (XML.jl 72.5% slower)
	LightXML             40.0 ms  (XML.jl 72.0% slower)

Collect tags (small)
	XML.jl            0.00037 ms
	EzXML             0.00108 ms  (XML.jl 65.6% faster)
	LightXML          0.00182 ms  (XML.jl 79.6% faster)

Collect tags (medium)
	XML.jl               4.77 ms
	EzXML                10.4 ms  (XML.jl 54.1% faster)
	LightXML             13.7 ms  (XML.jl 65.3% faster)

Parse SST (LazyNode)
	XML.jl             0.0382 ms
	Node (for ref)       9.93 ms  (XML.jl 99.6% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0279 ms
	Node (for ref)       17.5 ms  (XML.jl 99.8% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     19.4 ms
	LazyNode + write (normalize)     51.6 ms
	Node (for ref)       5.44 ms

SST: unformatted text
	LazyNode + is_simple_value     19.4 ms
	Node (for ref)       2.23 ms

Worksheet: collect rows
	children() (fresh Vector each call)     22.8 ms
	children!(buf, n) (reused buffer)     22.8 ms

Worksheet: attribute scan
	eachattribute        22.7 ms
	attributes() (materialize dict)     22.8 ms

Worksheet: single attr fetch
	get(c, "r", "")      22.8 ms
	attributes(c)["r"]     22.7 ms

Worksheet: <v> value
	is_simple_value      22.6 ms
	is_simple + simple_value     22.9 ms

XLSX sst_load! (end-to-end)
	LazyNode             27.3 ms
	LazyNode (entity-heavy)     19.7 ms

XLSX cell read (end-to-end)
	numeric ws           22.8 ms
	string ws            20.7 ms

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
