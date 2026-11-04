# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0134 ms
	XML.jl (SS)        0.0121 ms
	EzXML              0.0108 ms  (XML.jl 23.9% slower)
	LightXML           0.0106 ms  (XML.jl 25.9% slower)
	XMLDict             0.125 ms  (XML.jl 89.3% faster)

Parse (medium)
	XML.jl               66.5 ms
	XML.jl (SS)          63.3 ms
	EzXML                38.9 ms  (XML.jl 71.2% slower)
	LightXML             39.5 ms  (XML.jl 68.3% slower)
	XMLDict             365.0 ms  (XML.jl 81.8% faster)

Write (small)
	XML.jl            0.00436 ms
	EzXML             0.00567 ms  (XML.jl 23.0% faster)
	LightXML           0.0571 ms  (XML.jl 92.4% faster)

Write (medium)
	XML.jl               18.5 ms
	EzXML                20.8 ms  (XML.jl 11.0% faster)
	LightXML             29.7 ms  (XML.jl 37.9% faster)

Read file
	XML.jl               69.0 ms
	EzXML                42.2 ms  (XML.jl 63.5% slower)
	LightXML             41.1 ms  (XML.jl 67.8% slower)

Collect tags (small)
	XML.jl           0.000334 ms
	EzXML             0.00106 ms  (XML.jl 68.6% faster)
	LightXML          0.00172 ms  (XML.jl 80.6% faster)

Collect tags (medium)
	XML.jl               4.67 ms
	EzXML                9.77 ms  (XML.jl 52.2% faster)
	LightXML             13.2 ms  (XML.jl 64.7% faster)

Parse SST (LazyNode)
	XML.jl            1.91e-5 ms
	Node (for ref)       10.2 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            2.33e-5 ms
	Node (for ref)       18.1 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     7.13 ms
	LazyNode + write (normalize)     37.2 ms
	Node (for ref)       6.06 ms

SST: unformatted text
	LazyNode + is_simple_value     9.76 ms
	Node (for ref)       2.89 ms

Worksheet: collect rows
	children() (fresh Vector each call)     7.48 ms
	children!(buf, n) (reused buffer)     7.56 ms

Worksheet: attribute scan
	eachattribute        17.5 ms
	attributes() (materialize dict)     19.9 ms

Worksheet: single attr fetch
	get(c, "r", "")      14.7 ms
	attributes(c)["r"]     19.9 ms

Worksheet: <v> value
	is_simple_value      20.5 ms
	is_simple + simple_value     22.1 ms

XLSX sst_load! (end-to-end)
	LazyNode             14.9 ms
	LazyNode (entity-heavy)     12.2 ms

XLSX cell read (end-to-end)
	numeric ws           31.1 ms
	string ws            27.8 ms

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
