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
#   (4) TRAVERSE  — whole pre-built tree, one `eachchildnode` per visited node, every
#                   reader through the same protocol: Node / FlatNode / LazyNode
#
# Each line shows the median time, the per-evaluation allocation COUNT, and the
# allocated bytes — the count is an absolute: a per-node cost hides in a ratio but
# not in a counter. A v0.3.9 column for (2)/(3) is added by the subprocess
# pass in profile_vs_039.jl (run separately; the tag is pinned there to the
# document's comparison point).
#
#   julia --project=benchmarks benchmarks/profile.jl

using XML, BenchmarkTools, Statistics
import EzXML, LightXML

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 5

include(joinpath(@__DIR__, "XMarkGenerator.jl"))
using .XMarkGenerator
const FILE = joinpath(@__DIR__, "data", "xmark.xml")
if !isfile(FILE)
    mkpath(dirname(FILE)); generate_xmark(FILE, 1.0)
end
const S = read(FILE, String)
const SSNode = Node{SubString{String}}

ms(b)  = round(median(b).time / 1e6, digits = 2)
mib(b) = round(b.memory / 2^20, digits = 1)
# Each line decomposes its median: total (the user-lived figure, GC draws included) and the
# median GC share — the total minus it is the stable, reproducible work time.
function row(label, b)
    gc = median(b).gctime / 1e6
    tail = gc < 0.05 ? "" : string(" (GC ", round(gc, digits = 1), ")")
    println(rpad("  " * label, 26), lpad(ms(b), 8), " ms", rpad(tail, 12),
            lpad(b.allocs, 10), " allocs", lpad(mib(b), 8), " MiB")
end

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

#--------------------------------------------------------------# (4) TRAVERSE (per reader)
# Whole pre-built tree, one child-iterator per visited node — the per-cell hot-loop
# shape reported from spreadsheet workloads. One traversal function, one seam: each reader
# iterates children through its own protocol (`eachchildnode` for the lazy readers;
# `Node` stores its children and has no lazy child iterator), so the rows compare the
# readers' iteration protocols over identical work. The attribute sweep adds
# `eachattribute`.
_childiter(n::Node) = something(XML.children(n), ())
_childiter(n) = XML.eachchildnode(n)
function traverse_walk(node)
    cnt = 1; acc = 0
    t = XML.tag(node);   t === nothing || (acc += sizeof(t))
    v = XML.value(node); v === nothing || (acc += sizeof(v))
    for k in _childiter(node)
        c2, a2 = traverse_walk(k); cnt += c2; acc += a2
    end
    (cnt, acc)
end
function attr_sweep(node)
    acc = 0
    for (k, v) in XML.eachattribute(node)
        acc += sizeof(k) + sizeof(v)
    end
    for ch in XML.eachchildnode(node)
        acc += attr_sweep(ch)
    end
    acc
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

println("\n=== (4) TRAVERSE — whole tree, one eachchildnode per node ===")
const LAZY = parse(S, LazyNode)
const FLAT = parse(S, FlatNode)
let lw = traverse_walk(LAZY), fw = traverse_walk(FLAT), nw = traverse_walk(TREE)
    println("validation — traverse nodes: Lazy=", lw[1], "  Flat=", fw[1], "  Node=", nw[1])
end
row("LazyNode",           @benchmark traverse_walk($LAZY))
row("FlatNode",           @benchmark traverse_walk($FLAT))
row("Node",               @benchmark traverse_walk($TREE))
row("LazyNode attr sweep",@benchmark attr_sweep($LAZY))
println("\n(same recursive traversal for the three readers; a traversal that allocates per",
        "\n node shows it in the allocs column, not in a ratio)")

#--------------------------------------------------------------# (5) MEMORY-MAPPED SOURCE
# What a document held as something other than a `String` costs at the entry, and what a
# partial read costs after that — the workload the README documents memory mapping for. The
# corpus is mapped instead of read, and a CR LF twin is generated once beside it, because
# a document's line ends determine whether the entry passes the mapping through or
# rewrites it into the heap.
using Mmap, StringViews

const FILE_CRLF = joinpath(@__DIR__, "data", "xmark_crlf.xml")
isfile(FILE_CRLF) || write(FILE_CRLF, replace(S, "\n" => "\r\n"))

mapped_open(sv) = XML.Cursor(sv)
function mapped_read(sv, k)
    c = XML.Cursor(sv); n = 0; i = 0
    while XML.next!(c) !== nothing
        v = XML.value(c)
        v === nothing || (n += sizeof(v))
        i += 1
        i >= k && break
    end
    n
end

fine(t) = t < 1e3  ? string(round(t, digits = 1), " ns") :
          t < 1e6  ? string(round(t / 1e3, digits = 2), " µs") :
                     string(round(t / 1e6, digits = 2), " ms")
# An entry that rewrites allocates the whole document on every open, so its median climbs
# with collector pressure; the minimum is the reproducible figure and is shown beside it.
function mrow(label, b)
    println(rpad("  " * label, 26), lpad(fine(median(b).time), 10), " med",
            lpad(fine(minimum(b).time), 10), " min",
            lpad(b.allocs, 9), " allocs", lpad(mib(b), 8), " MiB")
end

println("\n=== (5) MEMORY-MAPPED SOURCE — the entry, and what a partial read costs ===")
for (lbl, path) in (("LF", FILE), ("CR LF", FILE_CRLF))
    open(path) do io
        sv = StringView(Mmap.mmap(io))
        println("  source: ", lbl, " line ends → ", typeof(mapped_open(sv)))
        mrow("open", @benchmark mapped_open($sv))
        if lbl == "CR LF"
            mrow("open + 1 000 nodes", @benchmark mapped_read($sv, 1000))
            mrow("open + every node",  @benchmark mapped_read($sv, typemax(Int)))
        end
    end
end
println("\n(the entry either passes the mapping through or rewrites the document into the",
        "\n heap; the resulting Cursor type says which)")

#--------------------------------------------------------------# (6) INTERNAL GENERAL ENTITIES
# What XML 1.0 §4.4 inclusion costs, priced against a twin that parses to the SAME TREE, so any
# difference below belongs to the entity machinery and to nothing else. The twin declares three
# entities and references them where the plain corpus carries the words themselves, so those
# references disappear into the expansion; a fourth word is rewritten as a character reference,
# which survives the expansion and is what reaches the `:strict` reference check. Both
# populations are needed: `has_entities` is computed after the expansion, so a twin carrying
# only declared references would leave that check measuring nothing.

const FILE_ENT = joinpath(@__DIR__, "data", "xmark_entities.xml")
function entity_twin(s)
    s = replace(s, r"\babout\b" => "&w1;", r"\bbetween\b" => "&w2;", r"\btogether\b" => "&w3;")
    s = replace(s, r"\bexample\b" => "&#101;xample")
    dt = "<!DOCTYPE site [<!ENTITY w1 \"about\"><!ENTITY w2 \"between\"><!ENTITY w3 \"together\">]>\n"
    i = findfirst("?>\n", s)
    string(SubString(s, 1, last(i)), dt, SubString(s, last(i) + 1))
end
isfile(FILE_ENT) || write(FILE_ENT, entity_twin(S))
const SE = read(FILE_ENT, String)

println("\n=== (6) INTERNAL GENERAL ENTITIES — what §4.4 inclusion costs ===")
println("  invariant, twin parses to the same tree : ", parse(S, Node)[end] == parse(SE, Node)[end])
println("  declared references, lost to the expansion : ", length(collect(eachmatch(r"&w[123];", SE))))
println("  character references, kept through it     : ", length(collect(eachmatch(r"&#101;", SE))))
row("parse, no declarations",    @benchmark parse($S, Node))
row("parse, entities included",  @benchmark parse($SE, Node))
row("parse :strict, no decl",    @benchmark parse($S, Node; wellformed = :strict))
row("parse :strict, entities",   @benchmark parse($SE, Node; wellformed = :strict))
row("expansion pass alone",      @benchmark XML._expand_entities($SE))
row("prolog probe, no decl",     @benchmark XML._internal_entities($S))
#--------------------------------------------------------------# (7) CONSTRUCTIONS THE PLAIN CORPUS LACKS
# The plain corpus carries no reference, no attribute value that needs normalizing, no comment, no
# CDATA section, no processing instruction and no DOCTYPE, so nothing above has measured any of
# them. Two twins are generated beside it through the generator's opt-in features, each keeping the
# plain document's elements and attributes in the same order, so that a difference between a plain
# row and a twin row belongs to the construction and to nothing else. The escaped twin replaces one
# drawn word in ten by one carrying a predefined entity or a character reference, and gives every
# item and person a `note` attribute that needs decoding or XML 1.0 §3.3.3 white-space
# normalization. The markup twin writes one text child per item and person as a CDATA section
# followed by a comment and a processing instruction, under a DOCTYPE holding the schema's
# declarations.
const FILE_ESC = joinpath(@__DIR__, "data", "xmark_escaped.xml")
const FILE_MK  = joinpath(@__DIR__, "data", "xmark_markup.xml")
isfile(FILE_ESC) || generate_xmark(FILE_ESC, 1.0; features = Features(text_every = 10, attr_every = 1))
isfile(FILE_MK)  || generate_xmark(FILE_MK,  1.0; features = Features(markup_every = 1, doctype = true))
const SESC = read(FILE_ESC, String)
const SM = read(FILE_MK, String)

# The twin invariant, checked rather than assumed: the same element tags in the same order.
function next_element!(c)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && return XML.tag(c)
    end
    nothing
end
function same_elements(a, b)
    ca = XML.Cursor(a); cb = XML.Cursor(b)
    while true
        ta = next_element!(ca); tb = next_element!(cb)
        ta == tb || return false
        ta === nothing && return true
    end
end

# The share of the bytes that text tokens cover, and the share of text and attribute-value tokens
# carrying a `&`: what `has_entities` gates, and what the `:strict` reference check reads.
function token_shares(s)
    tb = 0; tn = 0; tr = 0; an = 0; ar = 0
    for tok in XML.XMLTokenizer.tokenize(s)
        if tok.kind === XML.XMLTokenizer.TokenKinds.TEXT
            tb += tok.ncodeunits; tn += 1; tr += tok.has_entities
        elseif tok.kind === XML.XMLTokenizer.TokenKinds.ATTR_VALUE
            an += 1; ar += tok.has_entities
        end
    end
    (text = tb / ncodeunits(s), text_ref = tr / tn, attr_ref = ar / an)
end
pct(x) = string(round(100x, digits = 1), " %")

println("\n=== (7) CONSTRUCTIONS THE PLAIN CORPUS LACKS — twins of the same structure ===")
const LAZY_E = parse(SESC, LazyNode); const FLAT_E = parse(SESC, FlatNode)
const LAZY_M = parse(SM, LazyNode); const FLAT_M = parse(SM, FlatNode)
println("  invariant, same elements in the same order:  escaped=", same_elements(S, SESC),
        "  markup=", same_elements(S, SM))
println("  nodes:  plain=", traverse_walk(LAZY)[1], "  escaped=", traverse_walk(LAZY_E)[1],
        "  markup=", traverse_walk(LAZY_M)[1])
let e = token_shares(SESC)
    println("  escaped twin, tokens carrying a reference:  text ", pct(e.text_ref),
            "  attribute values ", pct(e.attr_ref))
end
for (lbl, s, lz, fl) in (("plain", S, LAZY, FLAT), ("escaped", SESC, LAZY_E, FLAT_E),
                          ("markup", SM, LAZY_M, FLAT_M))
    row("Cursor stream, $lbl",   @benchmark cursor_stream($s))
    row("parse → DOM, $lbl",     @benchmark parse($s, Node))
    row("parse SubString, $lbl", @benchmark parse($s, SSNode))
    row("LazyNode walk, $lbl",   @benchmark traverse_walk($lz))
    row("attr sweep, $lbl",      @benchmark attr_sweep($lz))
    row("FlatNode walk, $lbl",   @benchmark traverse_walk($fl))
end
const DTD_VALUE = XML.value(first(c for c in XML.children(LAZY_M) if XML.nodetype(c) === XML.DTD))
mrow("parse_dtd, the schema",   @benchmark XML.parse_dtd($DTD_VALUE))
println("\n(same rows as (1), (2) and (4) over the three documents; the DOCTYPE holds 74 element",
        "\n and 14 attribute-list declarations)")

#--------------------------------------------------------------# (8) WELL-FORMEDNESS LEVELS
# What `wellformed = :strict` adds over `:structural`: a character-range scan of every text,
# attribute value, comment, CDATA section and processing-instruction body, and a check of every
# character reference in a token that carries one. The first scales with the document's text
# share, the second with its reference density. The plain corpus measures the first alone, its
# escaped twin both, and a document made of the corpus's character data alone puts the text share
# at one. `:lenient` and `:structural` differ only in the document-shape checks.
const TEXT_ONLY = string("<doc>", replace(S, r"<[^>]*>" => ""), "</doc>")
println("\n=== (8) WELL-FORMEDNESS LEVELS — what :strict adds ===")
println("  text share of the bytes:  plain ", pct(token_shares(S).text), "  escaped ",
        pct(token_shares(SESC).text), "  text-only ", pct(token_shares(TEXT_ONLY).text),
        " (", round(ncodeunits(TEXT_ONLY) / 1e6, digits = 1), " MB)")
row("plain :lenient",        @benchmark parse($S, Node; wellformed = :lenient))
row("plain :structural",     @benchmark parse($S, Node; wellformed = :structural))
row("plain :strict",         @benchmark parse($S, Node; wellformed = :strict))
row("escaped :structural",   @benchmark parse($SESC, Node; wellformed = :structural))
row("escaped :strict",       @benchmark parse($SESC, Node; wellformed = :strict))
row("text-only :structural", @benchmark parse($TEXT_ONLY, Node; wellformed = :structural))
row("text-only :strict",     @benchmark parse($TEXT_ONLY, Node; wellformed = :strict))
println("\n(the character-range scan costs in proportion to the text share; the reference check",
        "\n runs only on a token that carries a `&`, so never on the plain corpus)")
