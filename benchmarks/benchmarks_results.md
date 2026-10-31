# XML.jl Benchmarks

```
Parse (small)
	XML.jl              0.013 ms
	XML.jl (SS)         0.012 ms
	EzXML              0.0112 ms  (XML.jl 16.1% slower)
	LightXML            0.011 ms  (XML.jl 17.4% slower)
	XMLDict             0.124 ms  (XML.jl 89.6% faster)

Parse (medium)
	XML.jl               63.4 ms
	XML.jl (SS)          62.0 ms
	EzXML                37.7 ms  (XML.jl 68.5% slower)
	LightXML             37.7 ms  (XML.jl 68.2% slower)
	XMLDict             318.0 ms  (XML.jl 80.1% faster)

Write (small)
	XML.jl            0.00414 ms
	EzXML             0.00565 ms  (XML.jl 26.7% faster)
	LightXML           0.0574 ms  (XML.jl 92.8% faster)

Write (medium)
	XML.jl               18.2 ms
	EzXML                20.6 ms  (XML.jl 11.8% faster)
	LightXML             30.7 ms  (XML.jl 40.9% faster)

Read file
	XML.jl               66.8 ms
	EzXML                38.4 ms  (XML.jl 73.7% slower)
	LightXML             39.3 ms  (XML.jl 69.9% slower)

Collect tags (small)
	XML.jl           0.000345 ms
	EzXML             0.00106 ms  (XML.jl 67.6% faster)
	LightXML          0.00176 ms  (XML.jl 80.4% faster)

Collect tags (medium)
	XML.jl               4.84 ms
	EzXML                9.92 ms  (XML.jl 51.2% faster)
	LightXML             13.6 ms  (XML.jl 64.3% faster)

Parse SST (LazyNode)
	XML.jl             2.3e-5 ms
	Node (for ref)       9.68 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            1.91e-5 ms
	Node (for ref)       16.7 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     5.78 ms
	LazyNode + write (normalize)     34.1 ms
	Node (for ref)       4.67 ms

SST: unformatted text
	LazyNode + is_simple_value     9.67 ms
	Node (for ref)       2.13 ms

Worksheet: collect rows
	children() (fresh Vector each call)     7.49 ms
	children!(buf, n) (reused buffer)     7.46 ms

Worksheet: attribute scan
	eachattribute        17.1 ms
	attributes() (materialize dict)     19.9 ms

Worksheet: single attr fetch
	get(c, "r", "")      14.7 ms
	attributes(c)["r"]     19.8 ms

Worksheet: <v> value
	is_simple_value      20.3 ms
	is_simple + simple_value     22.6 ms

XLSX sst_load! (end-to-end)
	LazyNode             14.1 ms
	LazyNode (entity-heavy)     11.5 ms

XLSX cell read (end-to-end)
	numeric ws           30.6 ms
	string ws            27.5 ms

```

```julia
versioninfo()
# Julia Version 1.13.3
# Commit 67ac47b9cd8 (2026-10-25 15:28 UTC)
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
