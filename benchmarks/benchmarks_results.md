# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0156 ms
	XML.jl (SS)        0.0141 ms
	EzXML              0.0133 ms  (XML.jl 17.2% slower)
	LightXML           0.0112 ms  (XML.jl 38.9% slower)
	XMLDict             0.116 ms  (XML.jl 86.5% faster)

Parse (medium)
	XML.jl               77.6 ms
	XML.jl (SS)          74.6 ms
	EzXML                46.3 ms  (XML.jl 67.7% slower)
	LightXML             37.5 ms  (XML.jl 106.9% slower)
	XMLDict             367.0 ms  (XML.jl 78.9% faster)

Write (small)
	XML.jl             0.0056 ms
	EzXML             0.00556 ms  (~same)
	LightXML           0.0582 ms  (XML.jl 90.4% faster)

Write (medium)
	XML.jl               26.8 ms
	EzXML                21.2 ms  (XML.jl 26.4% slower)
	LightXML             30.1 ms  (XML.jl 11.0% faster)

Read file
	XML.jl               81.9 ms
	EzXML                58.5 ms  (XML.jl 40.1% slower)
	LightXML             38.4 ms  (XML.jl 113.1% slower)

Collect tags (small)
	XML.jl           0.000369 ms
	EzXML             0.00112 ms  (XML.jl 67.2% faster)
	LightXML          0.00187 ms  (XML.jl 80.3% faster)

Collect tags (medium)
	XML.jl               4.83 ms
	EzXML                9.44 ms  (XML.jl 48.8% faster)
	LightXML             14.2 ms  (XML.jl 65.9% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       12.2 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       21.9 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     22.1 ms
	LazyNode + write (normalize)     55.0 ms
	Node (for ref)       5.71 ms

SST: unformatted text
	LazyNode + is_simple_value     25.5 ms
	Node (for ref)       2.38 ms

Worksheet: collect rows
	children() (fresh Vector each call)     24.7 ms
	children!(buf, n) (reused buffer)     24.7 ms

Worksheet: attribute scan
	eachattribute        24.6 ms
	attributes() (materialize dict)     24.7 ms

Worksheet: single attr fetch
	get(c, "r", "")      24.7 ms
	attributes(c)["r"]     24.7 ms

Worksheet: <v> value
	is_simple_value      24.6 ms
	is_simple + simple_value     24.7 ms

XLSX sst_load! (end-to-end)
	LazyNode             34.9 ms
	LazyNode (entity-heavy)     35.4 ms

XLSX cell read (end-to-end)
	numeric ws           25.6 ms
	string ws            23.3 ms

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
