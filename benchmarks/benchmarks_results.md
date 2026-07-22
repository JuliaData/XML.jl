# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0218 ms
	XML.jl (SS)        0.0195 ms
	EzXML              0.0133 ms  (XML.jl 64.3% slower)
	LightXML           0.0114 ms  (XML.jl 91.2% slower)
	XMLDict              0.11 ms  (XML.jl 80.1% faster)

Parse (medium)
	XML.jl              110.0 ms
	XML.jl (SS)         127.0 ms
	EzXML                46.8 ms  (XML.jl 134.7% slower)
	LightXML             47.1 ms  (XML.jl 133.3% slower)
	XMLDict             348.0 ms  (XML.jl 68.4% faster)

Write (small)
	XML.jl             0.0056 ms
	EzXML             0.00588 ms  (~same)
	LightXML           0.0592 ms  (XML.jl 90.5% faster)

Write (medium)
	XML.jl               27.7 ms
	EzXML                21.1 ms  (XML.jl 31.2% slower)
	LightXML             29.1 ms  (~same)

Read file
	XML.jl              102.0 ms
	EzXML                59.5 ms  (XML.jl 71.8% slower)
	LightXML             84.9 ms  (XML.jl 20.3% slower)

Collect tags (small)
	XML.jl           0.000371 ms
	EzXML             0.00111 ms  (XML.jl 66.4% faster)
	LightXML          0.00183 ms  (XML.jl 79.7% faster)

Collect tags (medium)
	XML.jl               5.63 ms
	EzXML                10.4 ms  (XML.jl 45.7% faster)
	LightXML             12.9 ms  (XML.jl 56.2% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       16.9 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       27.8 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     33.8 ms
	LazyNode + write (normalize)     70.7 ms
	Node (for ref)       5.46 ms

SST: unformatted text
	LazyNode + is_simple_value     39.1 ms
	Node (for ref)       2.39 ms

Worksheet: collect rows
	children() (fresh Vector each call)     36.2 ms
	children!(buf, n) (reused buffer)     36.3 ms

Worksheet: attribute scan
	eachattribute        36.3 ms
	attributes() (materialize dict)     36.3 ms

Worksheet: single attr fetch
	get(c, "r", "")      36.4 ms
	attributes(c)["r"]     36.4 ms

Worksheet: <v> value
	is_simple_value      36.4 ms
	is_simple + simple_value     36.1 ms

XLSX sst_load! (end-to-end)
	LazyNode             53.4 ms
	LazyNode (entity-heavy)     47.1 ms

XLSX cell read (end-to-end)
	numeric ws           36.1 ms
	string ws            33.3 ms

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
