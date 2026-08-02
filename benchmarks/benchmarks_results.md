# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0212 ms
	XML.jl (SS)        0.0195 ms
	EzXML              0.0132 ms  (XML.jl 60.6% slower)
	LightXML           0.0122 ms  (XML.jl 73.1% slower)
	XMLDict              0.11 ms  (XML.jl 80.7% faster)

Parse (medium)
	XML.jl               95.5 ms
	XML.jl (SS)          90.9 ms
	EzXML                47.3 ms  (XML.jl 102.1% slower)
	LightXML             37.5 ms  (XML.jl 154.7% slower)
	XMLDict             347.0 ms  (XML.jl 72.5% faster)

Write (small)
	XML.jl            0.00569 ms
	EzXML             0.00572 ms  (~same)
	LightXML           0.0583 ms  (XML.jl 90.2% faster)

Write (medium)
	XML.jl               25.7 ms
	EzXML                20.7 ms  (XML.jl 24.5% slower)
	LightXML             29.1 ms  (XML.jl 11.7% faster)

Read file
	XML.jl               83.9 ms
	EzXML                60.3 ms  (XML.jl 39.2% slower)
	LightXML             39.5 ms  (XML.jl 112.3% slower)

Collect tags (small)
	XML.jl           0.000372 ms
	EzXML             0.00112 ms  (XML.jl 66.8% faster)
	LightXML          0.00183 ms  (XML.jl 79.7% faster)

Collect tags (medium)
	XML.jl               4.79 ms
	EzXML                10.4 ms  (XML.jl 54.1% faster)
	LightXML             13.2 ms  (XML.jl 63.8% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       17.5 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       28.5 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     33.8 ms
	LazyNode + write (normalize)     73.3 ms
	Node (for ref)       5.56 ms

SST: unformatted text
	LazyNode + is_simple_value     40.0 ms
	Node (for ref)       2.38 ms

Worksheet: collect rows
	children() (fresh Vector each call)     36.1 ms
	children!(buf, n) (reused buffer)     36.5 ms

Worksheet: attribute scan
	eachattribute        36.0 ms
	attributes() (materialize dict)     36.1 ms

Worksheet: single attr fetch
	get(c, "r", "")      37.0 ms
	attributes(c)["r"]     36.3 ms

Worksheet: <v> value
	is_simple_value      36.1 ms
	is_simple + simple_value     36.3 ms

XLSX sst_load! (end-to-end)
	LazyNode             53.0 ms
	LazyNode (entity-heavy)     49.4 ms

XLSX cell read (end-to-end)
	numeric ws           36.1 ms
	string ws            33.7 ms

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
