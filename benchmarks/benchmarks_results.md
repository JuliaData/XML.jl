# XML.jl Benchmarks

```
Parse (small)
	XML.jl                 14 µs
	XML.jl (SS)            13 µs
	EzXML                  11 µs  (XML.jl 1.2× slower)
	LightXML               11 µs  (XML.jl 1.2× slower)
	XMLDict               140 µs  (XML.jl 10× faster)

Parse (medium)
	XML.jl                 71 ms
	XML.jl (SS)            61 ms
	EzXML                  41 ms  (XML.jl 1.8× slower)
	LightXML               42 ms  (XML.jl 1.7× slower)
	XMLDict               370 ms  (XML.jl 5.3× faster)

Write (small)
	XML.jl                4.4 µs
	EzXML                 5.8 µs  (XML.jl 1.3× faster)
	LightXML               58 µs  (XML.jl 13× faster)

Write (medium)
	XML.jl                 21 ms
	EzXML                  21 ms  (~same)
	LightXML               31 ms  (XML.jl 1.5× faster)

Read file
	XML.jl                 68 ms
	EzXML                  43 ms  (XML.jl 1.6× slower)
	LightXML               43 ms  (XML.jl 1.6× slower)

Collect tags (small)
	XML.jl                340 ns
	EzXML                 1.2 µs  (XML.jl 3.3× faster)
	LightXML              1.8 µs  (XML.jl 5.2× faster)

Collect tags (medium)
	XML.jl                4.5 ms
	EzXML                  12 ms  (XML.jl 2.5× faster)
	LightXML               13 ms  (XML.jl 2.7× faster)

Parse SST (LazyNode)
	XML.jl                 22 ns
	Node (for ref)         11 ms  (XML.jl 490000× faster)

Parse worksheet (LazyNode)
	XML.jl                 22 ns
	Node (for ref)         20 ms  (XML.jl 890000× faster)

SST: write each <si>
	LazyNode + write (zero-copy)      6.1 ms
	LazyNode + write (normalize)       37 ms
	Node (for ref)        6.1 ms

SST: unformatted text
	LazyNode + is_simple_value      9.9 ms
	Node (for ref)        2.9 ms

Worksheet: collect rows
	children() (fresh Vector each call)      7.5 ms
	children!(buf, n) (reused buffer)      7.5 ms

Worksheet: attribute scan
	eachattribute          18 ms
	attributes() (materialize dict)       20 ms

Worksheet: single attr fetch
	get(c, "r", "")        15 ms
	attributes(c)["r"]       20 ms

Worksheet: <v> value
	is_simple_value        21 ms
	is_simple + simple_value       24 ms

XLSX sst_load! (end-to-end)
	LazyNode               14 ms
	LazyNode (entity-heavy)       12 ms

XLSX cell read (end-to-end)
	numeric ws             33 ms
	string ws              29 ms

```

```julia
versioninfo()
# Julia Version 1.13.4
# Commit c1ac32ab733 (2026-11-13 17:30 UTC)
# Build Info:
#   Official https://julialang.org release
# Platform Info:
#   OS: macOS (arm64-apple-darwin27.2.0)
#   CPU: 10 × Apple M5
#   WORD_SIZE: 64
#   LLVM: libLLVM-20.1.8 (ORCJIT, apple-m1)
#   GC: Built with stock GC
# Threads: 1 default, 1 interactive, 1 GC (on 10 virtual cores)
```
