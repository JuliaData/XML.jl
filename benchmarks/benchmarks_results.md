# XML.jl Benchmarks

```
Parse (small)
	XML.jl                 14 µs
	XML.jl (SS)            12 µs
	EzXML                  11 µs  (XML.jl 1.2× slower)
	LightXML               11 µs  (XML.jl 1.3× slower)
	XMLDict               130 µs  (XML.jl 9.3× faster)

Parse (medium)
	XML.jl                 68 ms
	XML.jl (SS)            65 ms
	EzXML                  40 ms  (XML.jl 1.7× slower)
	LightXML               40 ms  (XML.jl 1.7× slower)
	XMLDict               350 ms  (XML.jl 5.1× faster)

Write (small)
	XML.jl                4.2 µs
	EzXML                 5.7 µs  (XML.jl 1.4× faster)
	LightXML               58 µs  (XML.jl 14× faster)

Write (medium)
	XML.jl                 20 ms
	EzXML                  21 ms  (~same)
	LightXML               31 ms  (XML.jl 1.6× faster)

Read file
	XML.jl                 69 ms
	EzXML                  40 ms  (XML.jl 1.7× slower)
	LightXML               40 ms  (XML.jl 1.7× slower)

Collect tags (small)
	XML.jl                340 ns
	EzXML                 1.1 µs  (XML.jl 3.2× faster)
	LightXML              1.7 µs  (XML.jl 5.1× faster)

Collect tags (medium)
	XML.jl                4.7 ms
	EzXML                  10 ms  (XML.jl 2.1× faster)
	LightXML               14 ms  (XML.jl 2.9× faster)

Parse SST (LazyNode)
	XML.jl                 21 ns
	Node (for ref)         11 ms  (XML.jl 490000× faster)

Parse worksheet (LazyNode)
	XML.jl                 21 ns
	Node (for ref)         19 ms  (XML.jl 890000× faster)

SST: write each <si>
	LazyNode + write (zero-copy)      6.4 ms
	LazyNode + write (normalize)       37 ms
	Node (for ref)        5.4 ms

SST: unformatted text
	LazyNode + is_simple_value      9.6 ms
	Node (for ref)        2.6 ms

Worksheet: collect rows
	children() (fresh Vector each call)      7.5 ms
	children!(buf, n) (reused buffer)      7.5 ms

Worksheet: attribute scan
	eachattribute          17 ms
	attributes() (materialize dict)       20 ms

Worksheet: single attr fetch
	get(c, "r", "")        15 ms
	attributes(c)["r"]       20 ms

Worksheet: <v> value
	is_simple_value        21 ms
	is_simple + simple_value       23 ms

XLSX sst_load! (end-to-end)
	LazyNode               15 ms
	LazyNode (entity-heavy)       12 ms

XLSX cell read (end-to-end)
	numeric ws             31 ms
	string ws              28 ms

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
