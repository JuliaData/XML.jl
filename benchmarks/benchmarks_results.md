# XML.jl Benchmarks

```
Parse (small)
	XML.jl              0.013 ms
	XML.jl (SS)        0.0118 ms
	EzXML              0.0113 ms  (XML.jl 14.8% slower)
	LightXML            0.011 ms  (XML.jl 17.8% slower)
	XMLDict             0.118 ms  (XML.jl 89.1% faster)

Parse (medium)
	XML.jl               65.4 ms
	XML.jl (SS)          61.0 ms
	EzXML                37.3 ms  (XML.jl 75.1% slower)
	LightXML             36.7 ms  (XML.jl 78.1% slower)
	XMLDict             323.0 ms  (XML.jl 79.8% faster)

Write (small)
	XML.jl            0.00599 ms
	EzXML             0.00585 ms  (~same)
	LightXML           0.0584 ms  (XML.jl 89.7% faster)

Write (medium)
	XML.jl               25.2 ms
	EzXML                20.1 ms  (XML.jl 25.4% slower)
	LightXML             30.4 ms  (XML.jl 17.1% faster)

Read file
	XML.jl               68.1 ms
	EzXML                38.9 ms  (XML.jl 75.1% slower)
	LightXML             38.7 ms  (XML.jl 76.1% slower)

Collect tags (small)
	XML.jl           0.000344 ms
	EzXML             0.00103 ms  (XML.jl 66.6% faster)
	LightXML          0.00175 ms  (XML.jl 80.3% faster)

Collect tags (medium)
	XML.jl               4.66 ms
	EzXML                8.88 ms  (XML.jl 47.5% faster)
	LightXML             12.4 ms  (XML.jl 62.4% faster)

Parse SST (LazyNode)
	XML.jl             0.0382 ms
	Node (for ref)       9.78 ms  (XML.jl 99.6% faster)

Parse worksheet (LazyNode)
	XML.jl             0.0279 ms
	Node (for ref)       16.8 ms  (XML.jl 99.8% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     8.88 ms
	LazyNode + write (normalize)     37.6 ms
	Node (for ref)       5.56 ms

SST: unformatted text
	LazyNode + is_simple_value     9.23 ms
	Node (for ref)       2.26 ms

Worksheet: collect rows
	children() (fresh Vector each call)     7.54 ms
	children!(buf, n) (reused buffer)     7.45 ms

Worksheet: attribute scan
	eachattribute        16.8 ms
	attributes() (materialize dict)     19.4 ms

Worksheet: single attr fetch
	get(c, "r", "")      14.3 ms
	attributes(c)["r"]     19.3 ms

Worksheet: <v> value
	is_simple_value      19.8 ms
	is_simple + simple_value     24.6 ms

XLSX sst_load! (end-to-end)
	LazyNode             16.2 ms
	LazyNode (entity-heavy)     11.5 ms

XLSX cell read (end-to-end)
	numeric ws           30.2 ms
	string ws            27.5 ms

```

```julia
versioninfo()
# Julia Version 1.13.0
# Commit d1c37793dd2 (2026-09-09 19:00 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin25.6.0)
#   CPU: 10 × Apple M5
#   WORD_SIZE: 64
#   LLVM: libLLVM-20.1.8 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 1 default, 1 interactive, 1 GC (on 10 virtual cores)
```
