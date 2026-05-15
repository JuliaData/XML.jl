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
    doc = read(catalog_path, Node)
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
                entities = get(attrs, "ENTITIES", ""),
                id = get(attrs, "ID", ""),
                uri = joinpath(base_dir, attrs["URI"]),
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
        for test in valid_tests
            isfile(test.uri) || continue
            try
                doc = read(test.uri, Node)
                @test nodetype(doc) == Document
                n_pass += 1
            catch e
                n_fail += 1
                push!(failures, "$(test.id): $e")
            end
        end
        if n_fail > 0
            @warn "W3C well-formed: $n_pass passed, $n_fail failed" failures=first(failures, 20)
        end
        @info "W3C well-formed: $n_pass / $(n_pass + n_fail) passed"
    end

    @testset "Not-well-formed documents should fail to parse" begin
        n_pass = 0
        n_fail = 0
        failures = String[]
        for test in notwf_tests
            isfile(test.uri) || continue
            try
                read(test.uri, Node)
                n_fail += 1
                push!(failures, test.id)
            catch
                @test true
                n_pass += 1
            end
        end
        if n_fail > 0
            @warn "W3C not-well-formed: $n_pass rejected, $n_fail incorrectly accepted" failures=first(failures, 20)
        end
        @info "W3C not-well-formed: $n_pass / $(n_pass + n_fail) correctly rejected"
    end
end
