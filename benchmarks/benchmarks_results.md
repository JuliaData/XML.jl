# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0141 ms
	XML.jl (SS)        0.0126 ms
	EzXML              0.0115 ms  (XML.jl 22.9% slower)
	LightXML           0.0112 ms  (XML.jl 25.7% slower)
	XMLDict              0.13 ms  (XML.jl 89.1% faster)

Parse (medium)
	XML.jl               67.5 ms
	XML.jl (SS)          65.4 ms
	EzXML                40.3 ms  (XML.jl 67.5% slower)
	LightXML             41.2 ms  (XML.jl 64.0% slower)
	XMLDict             343.0 ms  (XML.jl 80.3% faster)

Write (small)
	XML.jl            0.00418 ms
	EzXML             0.00569 ms  (XML.jl 26.5% faster)
	LightXML            0.058 ms  (XML.jl 92.8% faster)

Write (medium)
	XML.jl               19.1 ms
	EzXML                22.4 ms  (XML.jl 14.9% faster)
	LightXML             31.3 ms  (XML.jl 39.1% faster)

Read file
	XML.jl               68.8 ms
	EzXML                40.5 ms  (XML.jl 69.9% slower)
	LightXML             40.6 ms  (XML.jl 69.3% slower)

Collect tags (small)
	XML.jl            0.00034 ms
	EzXML             0.00111 ms  (XML.jl 69.3% faster)
	LightXML          0.00175 ms  (XML.jl 80.6% faster)

Collect tags (medium)
	XML.jl               4.79 ms
	EzXML                10.4 ms  (XML.jl 53.7% faster)
	LightXML             13.1 ms  (XML.jl 63.3% faster)

Parse SST (LazyNode)
	XML.jl            2.15e-5 ms
	Node (for ref)       10.5 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl             2.2e-5 ms
	Node (for ref)       18.6 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     6.42 ms
	LazyNode + write (normalize)     35.9 ms
	Node (for ref)        5.2 ms

SST: unformatted text
	LazyNode + is_simple_value     10.0 ms
	Node (for ref)       2.47 ms

Worksheet: collect rows
	children() (fresh Vector each call)     7.55 ms
	children!(buf, n) (reused buffer)     7.54 ms

Worksheet: attribute scan
	eachattribute        17.2 ms
	attributes() (materialize dict)     19.5 ms

Worksheet: single attr fetch
	get(c, "r", "")      14.8 ms
	attributes(c)["r"]     19.6 ms

Worksheet: <v> value
	is_simple_value      20.2 ms
	is_simple + simple_value     22.5 ms

XLSX sst_load! (end-to-end)
	LazyNode             14.5 ms
	LazyNode (entity-heavy)     11.8 ms

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
