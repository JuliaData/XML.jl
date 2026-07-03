# benchmarks/profile.jl
#
# Decomposed, apples-to-apples performance profile for XML.jl v0.4 — answers
# "where does the time go, and how does it compare end-to-end?" rather than a
# single misleading "parse" number:
#
#   (1) STREAM    — file → events, no tree:   XML.jl Cursor  vs  EzXML StreamReader
#   (2) EXTRACT   — parse + pull every tag/text (node counts shown so the work is
#                   verifiably matched): XML.jl String / SubString  vs  EzXML  vs  LightXML
#   (3) DECOMPOSE — the XML.jl pipeline stages:  I/O · lex · build · traverse
#
# Each line shows median time and allocations. A v0.3.9 column for (2)/(3) is added
# by the subprocess pass in profile_vs_039.jl (run separately).
#
#   julia --project=benchmarks benchmarks/profile.jl

using XML, BenchmarkTools, Statistics
import EzXML, LightXML

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5

const FILE = joinpath(@__DIR__, "data", "xmark.xml")
if !isfile(FILE)
    include(joinpath(@__DIR__, "XMarkGenerator.jl"))
    using .XMarkGenerator
    mkpath(dirname(FILE)); generate_xmark(FILE, 1.0)
end
const S = read(FILE, String)
const SSNode = Node{SubString{String}}

ms(b)  = round(median(b).time / 1e6, digits = 2)
mib(b) = round(b.memory / 2^20, digits = 1)
row(label, b) = println(rpad("  " * label, 26), lpad(ms(b), 8), " ms   ", lpad(mib(b), 7), " MiB")

#--------------------------------------------------------------# (1) STREAM (no tree)
# Advance through every node touching tag + value — the streaming workload, zero tree built.
function cursor_stream(s)
    c = XML.Cursor(s); n = 0; acc = 0
    while XML.next!(c) !== nothing
        n += 1
        t = XML.tag(c);   t === nothing || (acc += sizeof(t))
        v = XML.value(c); v === nothing || (acc += sizeof(v))
    end
    (n, acc)
end
# EzXML SAX reader: iterate start/end events touching the node name.
function ezxml_stream(s)
    r = EzXML.StreamReader(IOBuffer(s)); n = 0; acc = 0
    for _ in r
        n += 1; acc += sizeof(EzXML.nodename(r))
    end
    close(r)
    (n, acc)
end

#--------------------------------------------------------------# (2) FULL EXTRACTION
# Return (node_count, bytes_touched) so the work is verifiable; tuple-return avoids Ref overhead.
function xml_walk(node)
    cnt = 1; acc = 0
    t = XML.tag(node);   t === nothing || (acc += sizeof(t))
    v = XML.value(node); v === nothing || (acc += sizeof(v))
    ch = XML.children(node)
    if ch !== nothing
        for k in ch
            c2, a2 = xml_walk(k); cnt += c2; acc += a2
        end
    end
    (cnt, acc)
end
xml_extract(s, ::Type{T}) where {T} = xml_walk(parse(s, T))

function ezxml_walk(node)
    cnt = 1; acc = sizeof(EzXML.nodename(node))
    for ch in EzXML.eachnode(node)
        c2, a2 = ezxml_walk(ch); cnt += c2; acc += a2
    end
    (cnt, acc)
end
ezxml_extract(s) = ezxml_walk(EzXML.root(EzXML.parsexml(s)))

function lightxml_walk(el)
    cnt = 1; acc = sizeof(LightXML.name(el))
    for ch in LightXML.child_elements(el)
        c2, a2 = lightxml_walk(ch); cnt += c2; acc += a2
    end
    (cnt, acc)
end
function lightxml_extract(s)
    d = LightXML.parse_string(s)
    out = lightxml_walk(LightXML.root(d))
    LightXML.free(d)
    out
end

#--------------------------------------------------------------# (3) DECOMPOSE (XML.jl)
function lexcount(s)
    n = 0
    for _ in XML.XMLTokenizer.tokenize(s); n += 1; end
    n
end

#--------------------------------------------------------------# Validate (cheap) then benchmark
println("file: ", round(length(S) / 1e6, digits = 2), " MB")
cs, es = cursor_stream(S), ezxml_stream(S)
xe, ee, le = xml_extract(S, Node), ezxml_extract(S), lightxml_extract(S)
println("validation — stream events:  Cursor=", cs[1], "  EzXML=", es[1])
println("validation — extract nodes:  XML.jl=", xe[1], "  EzXML=", ee[1], "  LightXML(elem only)=", le[1])
println("validation — lex tokens:     ", lexcount(S))
println("validation — bytes touched:  XML.jl=", xe[2], "  EzXML=", ee[2], "  (sanity, should be same order)\n")

println("=== (1) STREAM — file → events, no tree built ===")
row("XML.jl Cursor",      @benchmark cursor_stream($S))
row("EzXML StreamReader", @benchmark ezxml_stream($S))

println("\n=== (2) FULL EXTRACTION — parse + pull every tag/text ===")
row("XML.jl (String)",    @benchmark xml_extract($S, Node))
row("XML.jl (SubString)", @benchmark xml_extract($S, SSNode))
row("EzXML",              @benchmark ezxml_extract($S))
row("LightXML (elem)",    @benchmark lightxml_extract($S))

println("\n=== (3) DECOMPOSE — XML.jl pipeline stages ===")
const TREE = parse(S, Node)
row("read file (I/O)",    @benchmark read(FILE, String))
row("lex only (tokenize)",@benchmark lexcount($S))
row("parse → DOM",        @benchmark parse($S, Node))
row("traverse only",      @benchmark xml_walk($TREE))
println("\n(build ≈ parse − lex; traverse is on a pre-built tree)")
