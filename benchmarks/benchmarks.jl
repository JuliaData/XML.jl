using XML
using XML: Element, nodetype, tag, children
using EzXML: EzXML
using XMLDict: XMLDict
using LightXML: LightXML
using BenchmarkTools
using DataFrames
using InteractiveUtils

include("XMarkGenerator.jl")
using .XMarkGenerator

BenchmarkTools.DEFAULT_PARAMETERS.seconds = 10
BenchmarkTools.DEFAULT_PARAMETERS.samples = 20000

#-----------------------------------------------------------------------------# Test data
# Small file (~120 lines)
small_file = joinpath(@__DIR__, "..", "test", "data", "books.xml")
small_xml = read(small_file, String)

# Medium file (generated XMark auction XML, ~14 MB)
medium_file = joinpath(@__DIR__, "data", "xmark.xml")
if !isfile(medium_file)
    mkpath(dirname(medium_file))
    @info "Generating XMark benchmark XML..."
    generate_xmark(medium_file, 1.0)
end
medium_xml = read(medium_file, String)

df = DataFrame(kind=String[], name=String[], bench=BenchmarkTools.Trial[])

macro add_benchmark(kind, name, expr...)
    esc(:(let
        @info string($kind, " - ", $name)
        bench = @benchmark $(expr...)
        push!(df, (; kind=$kind, name=$name, bench))
    end))
end

const SSNode = Node{SubString{String}}

#-----------------------------------------------------------------------------# Parse (small)
@add_benchmark "Parse (small)" "XML.jl" parse($small_xml, Node)
@add_benchmark "Parse (small)" "XML.jl (SS)" parse($small_xml, SSNode)
@add_benchmark "Parse (small)" "EzXML" EzXML.parsexml($small_xml)
@add_benchmark "Parse (small)" "LightXML" LightXML.parse_string($small_xml)
@add_benchmark "Parse (small)" "XMLDict" XMLDict.xml_dict($small_xml)

#-----------------------------------------------------------------------------# Parse (medium)
@add_benchmark "Parse (medium)" "XML.jl" parse($medium_xml, Node)
@add_benchmark "Parse (medium)" "XML.jl (SS)" parse($medium_xml, SSNode)
@add_benchmark "Parse (medium)" "EzXML" EzXML.parsexml($medium_xml)
@add_benchmark "Parse (medium)" "LightXML" LightXML.parse_string($medium_xml)
@add_benchmark "Parse (medium)" "XMLDict" XMLDict.xml_dict($medium_xml)

#-----------------------------------------------------------------------------# Write (small)
@add_benchmark "Write (small)" "XML.jl" XML.write(o) setup=(o = parse(small_xml, Node))
@add_benchmark "Write (small)" "EzXML" sprint(print, o) setup=(o = EzXML.parsexml(small_xml))
@add_benchmark "Write (small)" "LightXML" LightXML.save_file(o, f) setup=(o = LightXML.parse_string(small_xml); f = tempname()) teardown=(LightXML.free(o); rm(f, force=true))

#-----------------------------------------------------------------------------# Write (medium)
@add_benchmark "Write (medium)" "XML.jl" XML.write(o) setup=(o = parse(medium_xml, Node))
@add_benchmark "Write (medium)" "EzXML" sprint(print, o) setup=(o = EzXML.parsexml(medium_xml))
@add_benchmark "Write (medium)" "LightXML" LightXML.save_file(o, f) setup=(o = LightXML.parse_string(medium_xml); f = tempname()) teardown=(LightXML.free(o); rm(f, force=true))

#-----------------------------------------------------------------------------# Read from file
@add_benchmark "Read file" "XML.jl" read($medium_file, Node)
@add_benchmark "Read file" "EzXML" EzXML.readxml($medium_file)
@add_benchmark "Read file" "LightXML" LightXML.parse_file($medium_file)

#-----------------------------------------------------------------------------# Collect element tags
function xml_collect_tags(node)
    out = String[]
    _xml_collect_tags!(out, node)
    out
end
function _xml_collect_tags!(out, node)
    for c in children(node)
        if nodetype(c) === Element
            push!(out, tag(c))
            _xml_collect_tags!(out, c)
        end
    end
end

function ezxml_collect_tags(node::EzXML.Node)
    out = String[]
    _ezxml_collect_tags!(out, node)
    out
end
function _ezxml_collect_tags!(out, node::EzXML.Node)
    for child in EzXML.eachelement(node)
        push!(out, child.name)
        _ezxml_collect_tags!(out, child)
    end
end

function lightxml_collect_tags(root::LightXML.XMLElement)
    out = String[]
    _lightxml_collect_tags!(out, root)
    out
end
function _lightxml_collect_tags!(out, el::LightXML.XMLElement)
    for child in LightXML.child_elements(el)
        push!(out, LightXML.name(child))
        _lightxml_collect_tags!(out, child)
    end
end

@add_benchmark "Collect tags (small)" "XML.jl" xml_collect_tags(o) setup=(o = parse(small_xml, Node))
@add_benchmark "Collect tags (small)" "EzXML" ezxml_collect_tags(o.root) setup=(o = EzXML.parsexml(small_xml))
@add_benchmark "Collect tags (small)" "LightXML" lightxml_collect_tags(LightXML.root(o)) setup=(o = LightXML.parse_string(small_xml)) teardown=(LightXML.free(o))

@add_benchmark "Collect tags (medium)" "XML.jl" xml_collect_tags(o) setup=(o = parse(medium_xml, Node))
@add_benchmark "Collect tags (medium)" "EzXML" ezxml_collect_tags(o.root) setup=(o = EzXML.parsexml(medium_xml))
@add_benchmark "Collect tags (medium)" "LightXML" lightxml_collect_tags(LightXML.root(o)) setup=(o = LightXML.parse_string(medium_xml)) teardown=(LightXML.free(o))

#-----------------------------------------------------------------------------# XLSX-pattern fixtures
# These fixtures mirror the shapes that XLSX.jl exercises:
# - `sst_xml` matches `xl/sharedStrings.xml` (lots of small `<si><t>…</t></si>` entries
#   separated by whitespace — the layout that exposes the LazyNode write/normalize choice)
# - `ws_xml` matches `xl/sheetN.xml` (a `<sheetData>` with many `<row>`s of `<c r=… s=… t=…><v>…</v></c>`)

@info "Generating XLSX-pattern fixtures..."

sst_xml = let buf = IOBuffer()
    print(buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    print(buf, "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"50000\" uniqueCount=\"50000\">\n")
    for i in 1:50000
        print(buf, "  <si><t>shared string value number ", i, "</t></si>\n")
    end
    print(buf, "</sst>")
    String(take!(buf))
end

ws_xml = let buf = IOBuffer()
    print(buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    print(buf, "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n")
    print(buf, "<sheetData>\n")
    for r in 1:3000
        print(buf, "  <row r=\"", r, "\">")
        for c in 1:15
            col = Char(UInt32('A') + c - 1)
            print(buf, "<c r=\"", col, r, "\" s=\"3\" t=\"n\"><v>", r * c, "</v></c>")
        end
        print(buf, "</row>\n")
    end
    print(buf, "</sheetData></worksheet>")
    String(take!(buf))
end

# String-heavy worksheet: cells reference the shared string table (`t="s"`, `<v>` = SST
# index). This is the most common real-world shape and the one where the `has_entities`
# short-circuit and zero-copy accessors matter most for XLSX.jl `readtable`.
ws_str_xml = let buf = IOBuffer()
    print(buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    print(buf, "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n")
    print(buf, "<sheetData>\n")
    for r in 1:5000
        print(buf, "  <row r=\"", r, "\">")
        for c in 1:8
            col = Char(UInt32('A') + c - 1)
            print(buf, "<c r=\"", col, r, "\" s=\"2\" t=\"s\"><v>", (r * c) % 50000, "</v></c>")
        end
        print(buf, "</row>\n")
    end
    print(buf, "</sheetData></worksheet>")
    String(take!(buf))
end

# Entity-heavy SST: every <t> needs decoding, exercising the `has_entities` slow path.
sst_entity_xml = let buf = IOBuffer()
    print(buf, "<sst count=\"50000\" uniqueCount=\"50000\">")
    for i in 1:50000
        print(buf, "<si><t>A &amp; B &lt;tag&gt; #", i, "</t></si>")
    end
    print(buf, "</sst>")
    String(take!(buf))
end

@info "  sst_xml: $(round(length(sst_xml) / 1024 / 1024, digits=2)) MB ($(50000) <si>)"
@info "  ws_xml:  $(round(length(ws_xml) / 1024 / 1024, digits=2)) MB ($(3000) <row> × $(15) <c>)"
@info "  ws_str_xml: $(round(length(ws_str_xml) / 1024 / 1024, digits=2)) MB ($(5000) <row> × $(8) string <c>)"
@info "  sst_entity_xml: $(round(length(sst_entity_xml) / 1024 / 1024, digits=2)) MB (entity-heavy)"

# Helper: walk a Node-based <si> subtree and concatenate its <t> text content.
function _node_unformatted(io::IO, el::Node{String})
    XML.tag(el) == "rPh" && return
    if XML.tag(el) == "t"
        if XML.is_simple(el)
            write(io, XML.simple_value(el))
        else
            v = XML.value(el)
            isnothing(v) || write(io, v)
        end
        return
    end
    for c in XML.children(el)
        _node_unformatted(io, c)
    end
end
_node_unformatted(el::Node{String}) = sprint(_node_unformatted, el)

#-----------------------------------------------------------------------------# Parse: XLSX shapes
@add_benchmark "Parse SST (LazyNode)" "XML.jl" parse($sst_xml, LazyNode)
@add_benchmark "Parse SST (LazyNode)" "Node (for ref)" parse($sst_xml, Node)
@add_benchmark "Parse worksheet (LazyNode)" "XML.jl" parse($ws_xml, LazyNode)
@add_benchmark "Parse worksheet (LazyNode)" "Node (for ref)" parse($ws_xml, Node)

#-----------------------------------------------------------------------------# SST loading (XLSX.jl sst.jl pattern)
# Mirrors `sst_load!`: stream <si> children, capture raw XML + unformatted text per entry.

@add_benchmark "SST: write each <si>" "LazyNode + write (zero-copy)" begin
    out = String[]
    sst_el = doc[end]
    for si in XML.eachchildnode(sst_el)
        XML.nodetype(si) === XML.Element || continue
        push!(out, XML.write(si))
    end
    out
end setup=(doc = parse(sst_xml, LazyNode))

@add_benchmark "SST: write each <si>" "LazyNode + write (normalize)" begin
    out = String[]
    sst_el = doc[end]
    for si in XML.eachchildnode(sst_el)
        XML.nodetype(si) === XML.Element || continue
        push!(out, XML.write(si; normalize=true))
    end
    out
end setup=(doc = parse(sst_xml, LazyNode))

@add_benchmark "SST: write each <si>" "Node (for ref)" begin
    out = String[]
    sst_el = doc[end]
    for si in XML.children(sst_el)
        XML.tag(si) == "si" || continue
        push!(out, XML.write(si))
    end
    out
end setup=(doc = parse(sst_xml, Node))

@add_benchmark "SST: unformatted text" "LazyNode + is_simple_value" begin
    out = Vector{Union{Nothing,SubString{String},String}}()
    sst_el = doc[end]
    for si in XML.eachchildnode(sst_el)
        XML.nodetype(si) === XML.Element || continue
        for t in XML.eachchildnode(si)
            XML.nodetype(t) === XML.Element || continue
            XML.tag(t) == "t" || continue
            push!(out, XML.is_simple_value(t))
        end
    end
    out
end setup=(doc = parse(sst_xml, LazyNode))

@add_benchmark "SST: unformatted text" "Node (for ref)" begin
    out = String[]
    sst_el = doc[end]
    for si in XML.children(sst_el)
        XML.tag(si) == "si" || continue
        push!(out, _node_unformatted(si))
    end
    out
end setup=(doc = parse(sst_xml, Node))

#-----------------------------------------------------------------------------# Worksheet: nested row/cell loops (XLSX.jl cell.jl pattern)
# Mirrors `Cell(c::LazyNode, ws)` and `get_rowcells!`: iterate <row>, then <c>, then attrs + <v>.

@add_benchmark "Worksheet: collect rows" "children() (fresh Vector each call)" begin
    sd = doc[end][1]  # <sheetData>
    XML.children(sd)
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: collect rows" "children!(buf, n) (reused buffer)" begin
    sd = doc[end][1]
    XML.children!(buf, sd)
end setup=(doc = parse(ws_xml, LazyNode); buf = XML.LazyNode{String}[])

@add_benchmark "Worksheet: attribute scan" "eachattribute" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            for (k, v) in XML.eachattribute(c)
                n += sizeof(v)
            end
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: attribute scan" "attributes() (materialize dict)" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            a = XML.attributes(c)
            isnothing(a) && continue
            for (_, v) in a
                n += sizeof(v)
            end
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: single attr fetch" "get(c, \"r\", \"\")" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            n += sizeof(get(c, "r", ""))
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: single attr fetch" "attributes(c)[\"r\"]" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            a = XML.attributes(c)
            isnothing(a) && continue
            n += sizeof(a["r"])
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: <v> value" "is_simple_value" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            for v in XML.eachchildnode(c)
                XML.nodetype(v) === XML.Element || continue
                val = XML.is_simple_value(v)
                isnothing(val) || (n += sizeof(val))
            end
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

@add_benchmark "Worksheet: <v> value" "is_simple + simple_value" begin
    n = 0
    sd = doc[end][1]
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            for v in XML.eachchildnode(c)
                XML.nodetype(v) === XML.Element || continue
                if XML.is_simple(v)
                    n += sizeof(XML.simple_value(v))
                end
            end
        end
    end
    n
end setup=(doc = parse(ws_xml, LazyNode))

#-----------------------------------------------------------------------------# End-to-end XLSX.jl hot loops
# The micro-benchmarks above isolate single operations. These mirror the *combined* work
# XLSX.jl actually does per entry, so a regression in any sub-operation (parse, accessor,
# entity short-circuit, iterator allocation) shows up where it matters for spreadsheet read
# performance.

# Mirrors XLSX.jl `sst.jl` `unformatted_text` / `gather_strings!`: recursively walk an
# <si> subtree concatenating <t> text content.
function _xlsx_unformatted(io::IO, e::XML.LazyNode)
    t = XML.tag(e)
    t == "rPh" && return nothing
    if t == "t"
        v = XML.is_simple_value(e)
        isnothing(v) || write(io, v)
    else
        for ch in XML.eachchildnode(e)
            XML.nodetype(ch) === XML.Element && _xlsx_unformatted(io, ch)
        end
    end
    nothing
end

# Mirrors XLSX.jl `sst.jl` `sst_load!`: stream <si>, capture raw XML + unformatted text.
@add_benchmark "XLSX sst_load! (end-to-end)" "LazyNode" begin
    sst_el = doc[end]
    shared = String[]
    unformatted = String[]
    for si in XML.eachchildnode(sst_el)
        XML.nodetype(si) === XML.Element || continue
        XML.tag(si) == "si" || continue
        push!(shared, XML.write(si))
        io = IOBuffer()
        _xlsx_unformatted(io, si)
        push!(unformatted, String(take!(io)))
    end
    (length(shared), length(unformatted))
end setup=(doc = parse(sst_xml, LazyNode))

# Mirrors XLSX.jl `cell.jl` `Cell(c, ws)` + `get_rowcells!`: per cell, read the r/s/t
# attributes and the <v> value, exactly as the reader does. Numeric worksheet.
@add_benchmark "XLSX cell read (end-to-end)" "numeric ws" begin
    sd = doc[end][1]
    ncells = 0
    acc = 0
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            ref = get(c, "r", "")
            t = get(c, "t", "")
            s = get(c, "s", "")
            acc += sizeof(ref) + sizeof(t) + sizeof(s)
            for child in XML.eachchildnode(c)
                XML.nodetype(child) === XML.Element || continue
                if XML.tag(child) == "v"
                    v = XML.is_simple_value(child)
                    isnothing(v) || (acc += sizeof(v))
                end
            end
            ncells += 1
        end
    end
    (ncells, acc)
end setup=(doc = parse(ws_xml, LazyNode))

# Same loop on the string-heavy worksheet (t="s", SST-indexed) — the common real shape
# and the one most sensitive to the entity short-circuit / zero-copy accessors.
@add_benchmark "XLSX cell read (end-to-end)" "string ws" begin
    sd = doc[end][1]
    ncells = 0
    acc = 0
    for row in XML.eachchildnode(sd)
        XML.nodetype(row) === XML.Element || continue
        for c in XML.eachchildnode(row)
            XML.nodetype(c) === XML.Element || continue
            ref = get(c, "r", "")
            t = get(c, "t", "")
            s = get(c, "s", "")
            acc += sizeof(ref) + sizeof(t) + sizeof(s)
            for child in XML.eachchildnode(c)
                XML.nodetype(child) === XML.Element || continue
                if XML.tag(child) == "v"
                    v = XML.is_simple_value(child)
                    isnothing(v) || (acc += sizeof(v))
                end
            end
            ncells += 1
        end
    end
    (ncells, acc)
end setup=(doc = parse(ws_str_xml, LazyNode))

# Realistic-string SST: entries containing characters that DO need entity decoding, so the
# `has_entities` slow path is exercised (catches regressions in the decode branch).
@add_benchmark "XLSX sst_load! (end-to-end)" "LazyNode (entity-heavy)" begin
    sst_el = doc[end]
    n = 0
    for si in XML.eachchildnode(sst_el)
        XML.nodetype(si) === XML.Element || continue
        XML.tag(si) == "si" || continue
        for t in XML.eachchildnode(si)
            XML.nodetype(t) === XML.Element || continue
            v = XML.is_simple_value(t)
            isnothing(v) || (n += sizeof(v))
        end
    end
    n
end setup=(doc = parse(sst_entity_xml, LazyNode))

#-----------------------------------------------------------------------------# Write benchmarks_results.md
_fmt_ms(t) = string(round(t, sigdigits=3), " ms")

function _compare_indicator(xml_ms, other_ms)
    ratio = xml_ms / other_ms
    pct = abs(round((ratio - 1) * 100, digits=1))
    ratio > 1.05 ? "(XML.jl $(pct)% slower)" : ratio < 0.95 ? "(XML.jl $(pct)% faster)" : "(~same)"
end

outfile = joinpath(@__DIR__, "benchmarks_results.md")
open(outfile, "w") do io
    println(io, "# XML.jl Benchmarks\n")
    println(io, "```")
    for kind in unique(df.kind)
        g = groupby(df, :kind)
        haskey(g, (;kind)) || continue
        sub = g[(;kind)]
        println(io, kind)
        # Find XML.jl baseline (first row starting with "XML.jl")
        xml_row = findfirst(r -> startswith(r.name, "XML.jl") && !contains(r.name, "(SS)"), eachrow(sub))
        xml_ms = isnothing(xml_row) ? nothing : median(sub[xml_row, :bench]).time / 1e6
        for row in eachrow(sub)
            ms = median(row.bench).time / 1e6
            indicator = ""
            if !isnothing(xml_ms) && !startswith(row.name, "XML.jl")
                indicator = "  " * _compare_indicator(xml_ms, ms)
            end
            println(io, "\t", rpad(row.name, 16), lpad(_fmt_ms(ms), 12), indicator)
        end
        println(io)
    end
    println(io, "```")

    println(io, "\n```julia")
    println(io, "versioninfo()")
    buf = IOBuffer()
    InteractiveUtils.versioninfo(buf)
    for line in eachline(IOBuffer(take!(buf)))
        println(io, "# ", line)
    end
    println(io, "```")
end

println("Results written to $outfile")
