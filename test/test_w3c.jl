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
using Downloads: download
using Tar

const W3C_URL = "https://www.w3.org/XML/Test/xmlts20130923.tar"
const W3C_DIR = joinpath(@__DIR__, "data", "w3c")
const W3C_TAR = joinpath(@__DIR__, "data", "xmlts20130923.tar")

function ensure_w3c_suite()
    isdir(joinpath(W3C_DIR, "xmlconf")) && return
    mkpath(W3C_DIR)
    if !isfile(W3C_TAR)
        @info "Downloading W3C XML Conformance Test Suite..."
        download(W3C_URL, W3C_TAR)
    end
    @info "Extracting W3C XML Conformance Test Suite..."
    open(W3C_TAR) do io
        Tar.extract(io, W3C_DIR)
    end
end

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

    @testset "Not-well-formed documents should fail to parse" begin
        n_pass = 0
        n_fail = 0
        failures = String[]
        for test in notwf_tests
            isfile(test.uri) || continue
            try
                read(test.uri, Node; wellformed = :strict)
                n_fail += 1
                push!(failures, test.id)
            catch
                n_pass += 1
            end
        end
        # XML.jl is non-validating and this suite runs at :strict, so it rejects structural and
        # syntactic ill-formedness but not the validity errors that need DTD processing (ID/IDREF,
        # attribute types, content models). It therefore does not reject all 1257 in-scope not-wf
        # cases of the pinned xmlts20130923 suite. Assert a no-regression floor on the count it does
        # reject, and raise it as coverage grows.
        @test n_pass >= 408
        n_fail > 0 && @info "W3C not-wf: $n_fail not yet rejected (out-of-scope validity errors: DTD/entity)" examples=first(failures, 20)
        @info "W3C not-well-formed: $n_pass / $(n_pass + n_fail) rejected"
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
    # from this ledger; what remains of that class is one attribute value where §3.3.3 has to
    # normalize the white space a character reference contributes through an entity.
    avn = "§3.3.3 normalization through an entity (#130): `&#13;&#10;` reaching an attribute value inside replacement text"
    att = "ATTLIST default attribute injection (§3.3.2, #131)"
    ntn = "notation declarations: Second Canonical Form prepends a DOCTYPE carrying <!NOTATION …>"
    for (reason, ids) in (
        avn => ["valid-sa-110"],
        att => ["valid-sa-044", "valid-sa-045", "valid-sa-046", "valid-sa-058", "valid-sa-080",
                "valid-sa-094", "valid-sa-096", "valid-sa-111", "v-sgml01",
                "ibm-invalid-P56-ibm56i03.xml"],
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

@testset "Canonical output matches the suite's out/ references" begin
    # Scope pin: the xmlts20130923 suite carries 262 reference pairs reachable at
    # ENTITIES="none" / XML 1.0. A lower count means the collector or a filter regressed.
    @test count(t -> isfile(t.uri) && isfile(t.output), canon_tests) == 262
    n_conforming = 0
    n_known = 0
    regressions = String[]
    for t in canon_tests
        (isfile(t.uri) && isfile(t.output)) || continue
        doc = read(t.uri, Node; wellformed = :strict)
        ok = canonical_xml(doc) == String(read(t.output))
        if haskey(CANON_KNOWN_FAIL, t.id)
            @test_broken ok  # ledgered gap: flips to an unexpected pass once its feature is implemented
            n_known += 1
        else
            ok || push!(regressions, t.id)
            @test ok
            n_conforming += ok
        end
    end
    isempty(regressions) || @warn "canonical-output regressions" regressions
    @info "W3C canonical output: $n_conforming byte-identical, $n_known ledgered gaps (CANON_KNOWN_FAIL)"
end
