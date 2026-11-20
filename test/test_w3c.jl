# W3C XML Conformance Test Suite
# https://www.w3.org/XML/Test/xmlts20130923.tar
#
# Test types:
#   - "valid": well-formed XML that is also valid (should parse successfully)
#   - "invalid": well-formed but not valid per DTD (should still parse — we're non-validating)
#   - "not-wf": not well-formed XML (should fail to parse)
#   - "error": optional errors (parser may or may not reject)
#
# We only run tests with ENTITIES="none" since XML.jl does not expand external entities.
# We skip XML 1.1 tests (VERSION="1.1" or RECOMMENDATION="XML1.1").
#
# Tests with an OUTPUT attribute also pin the parsed VALUES: the referenced out/ file is
# the expected parse result in canonical form, byte-compared in the last testset below.

using XML
using XML: Node, nodetype, Document
using Test
@isdefined(ensure_w3c_suite) || include("w3c_suite.jl")   # `suite.jl` includes it first

# Parse a test catalog XML and extract TEST entries
function parse_catalog(catalog_path::String)
    isfile(catalog_path) || return NamedTuple[]
    doc = read(catalog_path, Node; wellformed = :lenient)  # catalog is a multi-root fixture, not a doc under test
    tests = NamedTuple[]
    _collect_tests!(tests, doc, dirname(catalog_path))
    return tests
end

function _collect_tests!(tests, node, base_dir)
    for child in XML.children(node)
        nodetype(child) !== XML.Element && continue
        if XML.tag(child) == "TEST"
            attrs = XML.attributes(child)
            haskey(attrs, "URI") || continue
            push!(tests, (
                type = get(attrs, "TYPE", ""),
                entities = get(attrs, "ENTITIES", "none"),  # testcases.dtd defaults ENTITIES to "none" when the attribute is omitted
                id = get(attrs, "ID", ""),
                uri = joinpath(base_dir, attrs["URI"]),
                # OUTPUT points at the expected parse result in Second Canonical Form
                # (testcases.dtd: James Clark's canonical XML + NOTATION declarations)
                output = haskey(attrs, "OUTPUT") ? joinpath(base_dir, attrs["OUTPUT"]) : "",
                version = get(attrs, "VERSION", "1.0"),
                recommendation = get(attrs, "RECOMMENDATION", ""),
                # testcases.dtd: "Tests which apply only to certain editions of XML list
                # those editions in the EDITION attribute. An absent EDITION implies that
                # the test applies to all editions."
                edition = get(attrs, "EDITION", ""),
            ))
        elseif XML.tag(child) == "TESTCASES"
            # TESTCASES may have xml:base to adjust paths
            sub_base = get(XML.attributes(child), "xml:base", "")
            child_base = isempty(sub_base) ? base_dir : joinpath(base_dir, sub_base)
            _collect_tests!(tests, child, child_base)
        else
            _collect_tests!(tests, child, base_dir)
        end
    end
end

function is_xml11(test)
    test.version == "1.1" ||
    test.recommendation == "XML1.1" ||
    contains(test.recommendation, "XML1.1")
end

ensure_w3c_suite()

# Catalogs for XML 1.0 tests
const XMLCONF_DIR = joinpath(W3C_DIR, "xmlconf")
const CATALOGS = filter(isfile, [
    joinpath(XMLCONF_DIR, "xmltest", "xmltest.xml"),
    joinpath(XMLCONF_DIR, "sun", "sun-valid.xml"),
    joinpath(XMLCONF_DIR, "sun", "sun-invalid.xml"),
    joinpath(XMLCONF_DIR, "sun", "sun-not-wf.xml"),
    joinpath(XMLCONF_DIR, "sun", "sun-error.xml"),
    joinpath(XMLCONF_DIR, "oasis", "oasis.xml"),
    joinpath(XMLCONF_DIR, "ibm", "ibm_oasis_not-wf.xml"),
    joinpath(XMLCONF_DIR, "ibm", "ibm_oasis_valid.xml"),
    joinpath(XMLCONF_DIR, "ibm", "ibm_oasis_invalid.xml"),
    joinpath(XMLCONF_DIR, "eduni", "errata-2e", "errata2e.xml"),
    joinpath(XMLCONF_DIR, "eduni", "errata-3e", "errata3e.xml"),
    joinpath(XMLCONF_DIR, "eduni", "errata-4e", "errata4e.xml"),
    joinpath(XMLCONF_DIR, "eduni", "namespaces", "1.0", "rmt-ns10.xml"),
    joinpath(XMLCONF_DIR, "eduni", "misc", "ht-bh.xml"),
    joinpath(XMLCONF_DIR, "japanese", "japanese.xml"),
])

# Collect all tests
all_tests = NamedTuple[]
for catalog in CATALOGS
    append!(all_tests, parse_catalog(catalog))
end

# Filter: only ENTITIES="none", skip XML 1.1
xml10_tests = filter(t -> t.entities == "none" && !is_xml11(t), all_tests)

valid_tests = filter(t -> t.type in ("valid", "invalid"), xml10_tests)
notwf_tests = filter(t -> t.type == "not-wf", xml10_tests)

@info "W3C tests: $(length(valid_tests)) valid/invalid, $(length(notwf_tests)) not-wf (from $(length(all_tests)) total)"

#==============================================================================#
#         What each reader refuses among the not-well-formed documents         #
#==============================================================================#
# `w3c_notwf.tsv` records, for each not-well-formed case of the suite, the least strict
# reader that refuses it:
#
#   stream      every reader, `Cursor` and `LazyNode` included
#   cursor      `Node` and `FlatNode` at every level, and `Cursor`; a `LazyNode` reads it
#   lenient     `Node` and `FlatNode` at every level; `Cursor` and `LazyNode` read it
#   structural  `Node` and `FlatNode` from `:structural` up
#   strict      `Node` and `FlatNode` at `:strict` only
#   none        no reader
#
# One word says it for every reader: the levels are nested, `FlatNode` refuses what `Node`
# refuses, and `:lenient` refuses what a streaming reader refuses. The testset below checks
# each reader against the record, so that a change of any of them shows case by case.
#
# After a deliberate change, run the tests once with `XML_W3C_WRITE_RECORD=true` in the
# environment: the record is written again from what `Cursor`, `LazyNode` and `Node` do,
# and its diff shows which cases have moved.
const NOTWF_RECORD = joinpath(@__DIR__, "w3c_notwf.tsv")
const NOTWF_REFUSED_BY = Dict(
    "stream"     => (:cursor, :lazy, :lenient, :structural, :strict),
    "cursor"     => (:cursor, :lenient, :structural, :strict),
    "lenient"    => (:lenient, :structural, :strict),
    "structural" => (:structural, :strict),
    "strict"     => (:strict,),
    "none"       => (),
)

# A `LazyNode` document read to its end: every name, every attribute, every value.
function walk_lazy(n)
    nt = nodetype(n)
    if nt === Document
        foreach(walk_lazy, XML.children(n))
    elseif nt === XML.Element
        XML.tag(n)
        attrs = XML.attributes(n)
        attrs === nothing || foreach(identity, attrs)
        foreach(walk_lazy, XML.children(n))
    else
        XML.value(n)
    end
    return nothing
end

# A `Cursor` driven to the end of the document, reading every name, attribute and value.
function walk_cursor(uri)
    c = read(uri, Cursor)
    while next!(c) !== nothing
        if nodetype(c) === XML.Element
            XML.tag(c)
            foreach(identity, eachattribute!(c))
        else
            XML.value(c)
        end
    end
    return nothing
end

const NOTWF_READERS = (
    ("Cursor", :cursor, walk_cursor),
    ("LazyNode", :lazy, uri -> walk_lazy(read(uri, LazyNode))),
    ("Node :lenient", :lenient, uri -> read(uri, Node; wellformed = :lenient)),
    ("FlatNode :lenient", :lenient, uri -> read(uri, FlatNode; wellformed = :lenient)),
    ("Node :structural", :structural, uri -> read(uri, Node; wellformed = :structural)),
    ("FlatNode :structural", :structural, uri -> read(uri, FlatNode; wellformed = :structural)),
    ("Node :strict", :strict, uri -> read(uri, Node; wellformed = :strict)),
    ("FlatNode :strict", :strict, uri -> read(uri, FlatNode; wellformed = :strict)),
)

# A reader refuses a document when it raises one of the two errors that XML.jl raises on a
# malformed document. Any other exception is a defect of the reader, and is thrown again.
function refuses(readit, uri)
    try
        readit(uri)
        return false
    catch e
        e isa Union{ArgumentError, ErrorException} || rethrow()
        return true
    end
end

# A case that `:strict` does not refuse is a known gap when the suite lists it for the fifth
# edition, whose names `:strict` follows, and when it does not test the Namespaces
# recommendation, which XML.jl does not check.
is_known_gap(t) = (isempty(t.edition) || "5" in split(t.edition)) && !startswith(t.recommendation, "NS")

function read_notwf_record()
    record = Dict{String, String}()
    for line in Iterators.drop(eachline(NOTWF_RECORD), 1)      # the first line names the columns
        id, word = split(line, '\t')
        record[id] = word
    end
    return record
end

# The record written from what the readers do: `Node` stands for `FlatNode`, which the
# testset then checks against it.
function write_notwf_record(cases)
    readers = Dict(key => readit for (name, key, readit) in NOTWF_READERS if !startswith(name, "FlatNode"))
    open(NOTWF_RECORD, "w") do io
        println(io, "id\trefused_from")
        for t in cases
            refusing = Tuple(key for key in NOTWF_REFUSED_BY["stream"] if refuses(readers[key], t.uri))
            word = findfirst(==(refusing), NOTWF_REFUSED_BY)
            word === nothing && error("$(t.id) is refused by $refusing, which no word of the record says")
            println(io, t.id, '\t', word)
        end
    end
end

@testset "W3C Conformance" begin
    @testset "Well-formed documents should parse" begin
        n_pass = 0
        n_fail = 0
        failures = String[]
        # Read at :strict (the strongest level): every well-formed W3C doc must parse even under the
        # full content-level checks — this also guards :strict against false-positives on real XML.
        for test in valid_tests
            isfile(test.uri) || continue
            try
                doc = read(test.uri, Node; wellformed = :strict)
                @test nodetype(doc) == Document
                n_pass += 1
            catch e
                n_fail += 1
                push!(failures, "$(test.id): $e")
            end
        end
        n_fail > 0 && @warn "W3C well-formed docs that failed to parse" failures=first(failures, 20)
        @test n_fail == 0                  # every well-formed W3C doc must parse
        @info "W3C well-formed: $n_pass / $(n_pass + n_fail) passed"
    end

    @testset "Not-well-formed documents: what each reader refuses, case by case" begin
        cases = filter(t -> isfile(t.uri), notwf_tests)
        # Scope pin: the xmlts20130923 suite carries 1257 not-well-formed cases reachable at
        # ENTITIES="none" / XML 1.0. A lower count means the collector or a filter
        # regressed.
        @test length(cases) == 1257
        get(ENV, "XML_W3C_WRITE_RECORD", "") == "true" && write_notwf_record(cases)
        record = read_notwf_record()
        @test sort!(collect(keys(record))) == sort!([t.id for t in cases])   # one line per case
        counts = String[]
        @testset "$name" for (name, key, readit) in NOTWF_READERS
            n_refused = 0
            n_gaps = 0
            moved = String[]
            for t in cases
                expected = key in NOTWF_REFUSED_BY[get(record, t.id, "none")]
                refused = refuses(readit, t.uri)
                n_refused += refused
                if key === :strict && !expected && is_known_gap(t)
                    # `:strict` checks the syntax of the DTD only in part: most known gaps
                    # are errors inside the DTD. A gap that is closed shows as an unexpected
                    # pass, and the record must then be written again.
                    @test_broken refused
                    n_gaps += 1
                else
                    refused == expected ||
                        push!(moved, string(t.id, refused ? ": now refused" : ": no longer refused"))
                    @test refused == expected
                end
            end
            isempty(moved) ||
                @warn "W3C not-wf: $name no longer does what w3c_notwf.tsv records" moved=first(moved, 20)
            push!(counts, string(name, " ", n_refused, n_gaps > 0 ? " ($n_gaps known gaps)" : ""))
        end
        @info "W3C not-well-formed, refused out of $(length(cases)): " * join(counts, ", ")
    end
end

#==============================================================================#
#        Canonical-output comparison against the suite's out/ references       #
#==============================================================================#
# Tests with an OUTPUT attribute do dual duty (testcases.dtd): the document must parse,
# and the data reported must match the referenced out/ file, which is in "Second
# Canonical Form" — James Clark's canonical XML (xmltest/canonxml.html in the suite)
# plus a DOCTYPE carrying the NOTATION declarations when the document declares any.
# Canonical form makes every normalization decision byte-visible: attributes sorted,
# whitespace as explicit character references, entities expanded, comments and the
# XML declaration dropped, and no prolog/epilog whitespace (CanonXML ::= Pi* element Pi*).

function canonical_escape(io::IO, s::AbstractString)
    # Datachar: & < > " as named entities, tab/LF/CR as decimal references. All escaped
    # bytes are ASCII and multibyte UTF-8 units are all > 0x7F, so a byte loop can
    # neither split nor misread a multibyte character.
    for b in codeunits(s)
        if b == UInt8('&');      write(io, "&amp;")
        elseif b == UInt8('<');  write(io, "&lt;")
        elseif b == UInt8('>');  write(io, "&gt;")
        elseif b == UInt8('"');  write(io, "&quot;")
        elseif b == 0x09;        write(io, "&#9;")
        elseif b == 0x0A;        write(io, "&#10;")
        elseif b == 0x0D;        write(io, "&#13;")
        else;                    write(io, b)
        end
    end
end

function canonical_xml(io::IO, n)
    nt = nodetype(n)
    if nt == XML.Document
        # CanonXML ::= Pi* element Pi* — document-level whitespace, comments, the XML
        # declaration and the DOCTYPE are absent from the canonical form (the
        # notation-carrying DOCTYPE of Second Canonical Form is a ledgered gap below)
        for c in XML.children(n)
            ct = nodetype(c)
            (ct == XML.Element || ct == XML.ProcessingInstruction) && canonical_xml(io, c)
        end
    elseif nt == XML.Element
        write(io, '<'); write(io, XML.tag(n))
        atts = XML.attributes(n)
        if atts !== nothing
            for (name, val) in sort!(collect(atts); by = first)  # lexicographic, Unicode bit order
                write(io, ' '); write(io, name); write(io, "=\"")
                canonical_escape(io, val); write(io, '"')
            end
        end
        write(io, '>')
        foreach(c -> canonical_xml(io, c), XML.children(n))
        write(io, "</"); write(io, XML.tag(n)); write(io, '>')
    elseif nt == XML.Text || nt == XML.CData
        v = XML.value(n)
        v === nothing || canonical_escape(io, v)
    elseif nt == XML.ProcessingInstruction
        write(io, "<?"); write(io, XML.tag(n)); write(io, ' ')  # target/data separator: always one space
        v = XML.value(n)
        v === nothing || write(io, v)  # PI data is written raw; Datachar escaping does not apply
        write(io, "?>")
    end  # Declaration, Comment, DTD: not part of the canonical form
    return io
end
canonical_xml(n) = String(take!(canonical_xml(IOBuffer(), n)))

# Ledger of the reference pairs whose canonical form XML.jl does not reproduce yet,
# keyed by the conformance feature that closes them and its tracker issue. Every entry
# runs as @test_broken: implementing a feature makes its cases error as unexpected passes and
# must move out of here.
const CANON_KNOWN_FAIL = Dict{String, String}()
let
    # Line-end normalization (§2.11) is implemented, so its cases are absent from this
    # ledger; a case that combined it with another gap is listed under that remaining gap.
    # Internal general entities are included before the parse (§4.4.2), so their cases are absent
    # from this ledger.
    ntn = "notation declarations: Second Canonical Form prepends a DOCTYPE carrying <!NOTATION …>"
    for (reason, ids) in (
        ntn => ["valid-sa-069", "valid-sa-076", "valid-sa-090", "valid-sa-091", "sa02",
                "ibm-valid-P29-ibm29v01.xml",
                "ibm-valid-P56-ibm56v08.xml", "ibm-valid-P57-ibm57v01.xml", "ibm-valid-P58-ibm58v01.xml",
                "ibm-valid-P58-ibm58v02.xml", "ibm-valid-P82-ibm82v01.xml",
                "ibm-invalid-P58-ibm58i01.xml", "ibm-invalid-P58-ibm58i02.xml"],
    )
        for id in ids
            CANON_KNOWN_FAIL[id] = reason
        end
    end
end

canon_tests = filter(t -> !isempty(t.output), xml10_tests)

# Each reader that builds a tree is compared: each applies the declarations of the DOCTYPE
# and normalizes line ends at its own point. `LazyNode` checks no well-formedness, so it
# reads without the keyword.
canon_read(R, uri) = R === LazyNode ? read(uri, R) : read(uri, R; wellformed = :strict)

@testset "Canonical output matches the suite's out/ references" begin
    # Scope pin: the xmlts20130923 suite carries 262 reference pairs reachable at
    # ENTITIES="none" / XML 1.0. A lower count means the collector or a filter regressed.
    @test count(t -> isfile(t.uri) && isfile(t.output), canon_tests) == 262
    @testset "$R" for R in (Node, LazyNode, FlatNode)
        n_conforming = 0
        n_known = 0
        regressions = String[]
        for t in canon_tests
            (isfile(t.uri) && isfile(t.output)) || continue
            ok = canonical_xml(canon_read(R, t.uri)) == String(read(t.output))
            if haskey(CANON_KNOWN_FAIL, t.id)
                @test_broken ok  # ledgered gap: flips to an unexpected pass once its feature is implemented
                n_known += 1
            else
                ok || push!(regressions, t.id)
                @test ok
                n_conforming += ok
            end
        end
        isempty(regressions) || @warn "canonical-output regressions" R regressions
        @info "W3C canonical output, $R: $n_conforming byte-identical, $n_known ledgered gaps (CANON_KNOWN_FAIL)"
    end
end

# The same documents written with CR LF, as a Windows checkout writes them. Line ends are no
# part of a document's data (§2.11), so each reader must give the same canonical output. The
# text is read as `read` reads a file, then its line ends are made CR LF.
function crlf_text(uri)
    s = String(XML._normalize_bom(read(uri)))
    replace(replace(s, "\r\n" => "\n", "\r" => "\n"), "\n" => "\r\n")
end
canon_parse(R, s) = R === LazyNode ? parse(s, R) : parse(s, R; wellformed = :strict)

@testset "Canonical output of the same documents with CR LF line ends" begin
    @testset "$R" for R in (Node, LazyNode, FlatNode)
        regressions = String[]
        for t in canon_tests
            (isfile(t.uri) && isfile(t.output)) || continue
            haskey(CANON_KNOWN_FAIL, t.id) && continue
            ok = canonical_xml(canon_parse(R, crlf_text(t.uri))) == String(read(t.output))
            ok || push!(regressions, t.id)
            @test ok
        end
        isempty(regressions) ||
            @warn "canonical-output regressions with CR LF" R regressions
    end
end
