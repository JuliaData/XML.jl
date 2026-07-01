using XML
using XML: Document, Element, Declaration, Comment, CData, DTD, ProcessingInstruction, Text
using Downloads: download
using Test

#==============================================================================#
#                REMOTE XML FILE PARSING TESTS                                 #
#==============================================================================#
# These tests download publicly available XML files and verify that XML.jl can
# parse them without error.  A failed download (network issues, CI without
# internet, URL gone) is silently skipped — only parsing failures count as test
# failures.
#
# Not included in runtests.jl — run standalone:  julia --project test/test_remote_files.jl

function _try_download(url::AbstractString)::Union{String, Nothing}
    try
        path = download(url)
        return read(path, String)
    catch
        return nothing
    end
end

const REMOTE_XML_URLS = [
    # ---- W3Schools example files ----
    ("W3Schools note.xml",           "https://www.w3schools.com/xml/note.xml"),
    ("W3Schools cd_catalog.xml",     "https://www.w3schools.com/xml/cd_catalog.xml"),
    ("W3Schools plant_catalog.xml",  "https://www.w3schools.com/xml/plant_catalog.xml"),
    ("W3Schools simple.xml",         "https://www.w3schools.com/xml/simple.xml"),
    ("W3Schools books.xml",          "https://www.w3schools.com/xml/books.xml"),

    # ---- W3C SVG samples ----
    ("W3C SVG helloworld.svg",       "https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/helloworld.svg"),
    ("W3C SVG tiger.svg",            "https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/tiger.svg"),
    ("W3C SVG w3c.svg",              "https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/w3c.svg"),
    ("W3C SVG lineargradient2.svg",  "https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/lineargradient2.svg"),
    ("W3C SVG heart.svg",            "https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/heart.svg"),

    # ---- GitHub-hosted XML files ----
    ("JUnit XML complete example",   "https://raw.githubusercontent.com/testmoapp/junitxml/main/examples/junit-complete.xml"),
    ("JUnit XML basic example",      "https://raw.githubusercontent.com/testmoapp/junitxml/main/examples/junit-basic.xml"),
    ("PEPPOL invoice base example",  "https://raw.githubusercontent.com/OpenPEPPOL/peppol-bis-invoice-3/master/rules/examples/base-example.xml"),

    # ---- Maven Central POM (real-world XML with namespaces) ----
    ("Maven JUnit 4.13.2 POM",      "https://repo1.maven.org/maven2/junit/junit/4.13.2/junit-4.13.2.pom"),
    ("Maven Guava 33.0 POM",        "https://repo1.maven.org/maven2/com/google/guava/guava/33.0.0-jre/guava-33.0.0-jre.pom"),

    # ---- NASA RSS feed (live XML) ----
    ("NASA news RSS feed",           "https://www.nasa.gov/news-release/feed/"),
]

@testset "Remote XML Parsing" begin
    for (label, url) in REMOTE_XML_URLS
        @testset "$label" begin
            xml_str = _try_download(url)
            if isnothing(xml_str)
                @info "Skipping $label — download failed" url
                @test_skip false
            else
                doc = parse(xml_str, Node)
                @test nodetype(doc) == Document
                @test length(children(doc)) > 0

                # Verify at least one Element exists somewhere in the document
                has_element = any(x -> nodetype(x) == Element, children(doc))
                @test has_element

                # Verify write produces output and can be re-parsed
                xml_out = XML.write(doc)
                @test length(xml_out) > 0
                doc2 = parse(xml_out, Node)
                @test nodetype(doc2) == Document
            end
        end
    end
end
