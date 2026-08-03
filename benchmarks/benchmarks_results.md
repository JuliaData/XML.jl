# XML.jl Benchmarks

```
Parse (small)
	XML.jl             0.0158 ms
	XML.jl (SS)        0.0144 ms
	EzXML              0.0131 ms  (XML.jl 20.4% slower)
	LightXML           0.0114 ms  (XML.jl 38.0% slower)
	XMLDict             0.113 ms  (XML.jl 86.1% faster)

Parse (medium)
	XML.jl               77.4 ms
	XML.jl (SS)          71.0 ms
	EzXML                46.1 ms  (XML.jl 67.8% slower)
	LightXML             39.0 ms  (XML.jl 98.3% slower)
	XMLDict             352.0 ms  (XML.jl 78.0% faster)

Write (small)
	XML.jl            0.00559 ms
	EzXML             0.00577 ms  (~same)
	LightXML           0.0581 ms  (XML.jl 90.4% faster)

Write (medium)
	XML.jl               24.4 ms
	EzXML                21.5 ms  (XML.jl 13.7% slower)
	LightXML             28.3 ms  (XML.jl 13.8% faster)

Read file
	XML.jl               80.5 ms
	EzXML                59.0 ms  (XML.jl 36.3% slower)
	LightXML             38.8 ms  (XML.jl 107.2% slower)

Collect tags (small)
	XML.jl            0.00037 ms
	EzXML             0.00107 ms  (XML.jl 65.3% faster)
	LightXML          0.00183 ms  (XML.jl 79.8% faster)

Collect tags (medium)
	XML.jl               4.81 ms
	EzXML                8.99 ms  (XML.jl 46.5% faster)
	LightXML             13.1 ms  (XML.jl 63.3% faster)

Parse SST (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       12.5 ms  (XML.jl 100.0% faster)

Parse worksheet (LazyNode)
	XML.jl            4.96e-6 ms
	Node (for ref)       21.3 ms  (XML.jl 100.0% faster)

SST: write each <si>
	LazyNode + write (zero-copy)     22.0 ms
	LazyNode + write (normalize)     55.3 ms
	Node (for ref)       5.58 ms

SST: unformatted text
	LazyNode + is_simple_value     24.5 ms
	Node (for ref)       2.24 ms

Worksheet: collect rows
	children() (fresh Vector each call)     24.7 ms
	children!(buf, n) (reused buffer)     24.6 ms

Worksheet: attribute scan
	eachattribute        24.7 ms
	attributes() (materialize dict)     25.0 ms

Worksheet: single attr fetch
	get(c, "r", "")      24.8 ms
	attributes(c)["r"]     24.7 ms

Worksheet: <v> value
	is_simple_value      24.6 ms
	is_simple + simple_value     24.9 ms

XLSX sst_load! (end-to-end)
	LazyNode             33.1 ms
	LazyNode (entity-heavy)     33.2 ms

XLSX cell read (end-to-end)
	numeric ws           24.8 ms
	string ws            22.7 ms

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
