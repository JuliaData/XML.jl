# XML.jl Benchmarks

```
Parse (small)
	XML.jl              0.013 ms
	XML.jl (SS)        0.0117 ms
	EzXML              0.0113 ms  (XML.jl 14.3% slower)
	LightXML           0.0112 ms  (XML.jl 16.0% slower)
	XMLDict             0.117 ms  (XML.jl 88.9% faster)

Parse (medium)
	XML.jl               63.3 ms
	XML.jl (SS)          60.9 ms
	EzXML                37.7 ms  (XML.jl 68.0% slower)
	LightXML             37.3 ms  (XML.jl 69.8% slower)
	XMLDict             330.0 ms  (XML.jl 80.8% faster)

Write (small)
	XML.jl             0.0059 ms
	EzXML             0.00595 ms  (~same)
	LightXML           0.0581 ms  (XML.jl 89.8% faster)

Write (medium)
	XML.jl               24.7 ms
	EzXML                21.0 ms  (XML.jl 17.5% slower)
	LightXML             30.5 ms  (XML.jl 18.9% faster)

Read file
	XML.jl               66.1 ms
	EzXML                39.3 ms  (XML.jl 68.4% slower)
	LightXML             40.7 ms  (XML.jl 62.5% slower)

Collect tags (small)
	XML.jl           0.000338 ms
	EzXML             0.00106 ms  (XML.jl 68.1% faster)
	LightXML          0.00173 ms  (XML.jl 80.5% faster)

Collect tags (medium)
	XML.jl               4.73 ms
	EzXML                9.13 ms  (XML.jl 48.2% faster)
	LightXML             13.3 ms  (XML.jl 64.5% faster)

Parse SST (LazyNode)
	XML.jl             0.0382 ms
	Node (for ref)        9.7 ms  (XML.jl 99.6% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0279 ms
	Node (for ref)       17.5 ms  (XML.jl 99.8% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     8.81 ms
	LazyNode + write (normalize)     37.7 ms
	Node (for ref)       5.59 ms

SST: unformatted text
	LazyNode + is_simple_value     9.01 ms
	Node (for ref)       2.19 ms

Worksheet: collect rows
	children() (fresh Vector each call)     8.59 ms
	children!(buf, n) (reused buffer)     9.51 ms

Worksheet: attribute scan
	eachattribute        16.6 ms
	attributes() (materialize dict)     19.0 ms

Worksheet: single attr fetch
	get(c, "r", "")      14.7 ms
	attributes(c)["r"]     19.1 ms

Worksheet: <v> value
	is_simple_value      19.6 ms
	is_simple + simple_value     21.4 ms

XLSX sst_load! (end-to-end)
	LazyNode             17.8 ms
	LazyNode (entity-heavy)     11.2 ms

XLSX cell read (end-to-end)
	numeric ws           30.3 ms
	string ws            26.8 ms

```

```julia
versioninfo()
# Julia Version 1.13.1
# Commit 96ca370cf0e (2026-09-25 19:34 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin27.0.0)
#   CPU: 10 × Apple M5
#   WORD_SIZE: 64
#   LLVM: libLLVM-20.1.8 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 1 default, 1 interactive, 1 GC (on 10 virtual cores)
```
