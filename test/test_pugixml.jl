# Test cases inspired by pugixml (https://github.com/zeux/pugixml, MIT license)
# Translated from tests/test_parse.cpp and tests/test_xpath.cpp

using XML
using XML: Node, nodetype, Document, Element, Comment, CData, ProcessingInstruction, Text, Declaration
using XML: tag, value, children, attributes, simple_value, xpath
using Test

@testset "pugixml-inspired" begin

    #==========================================================================#
    #                        Processing Instructions                           #
    #==========================================================================#
    @testset "PI parsing" begin
        doc = parse("<?pi?><root/>", Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(pis) == 1

        doc = parse("<?pi value?><root/>", Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(pis) == 1

        doc = parse("<?target  \r\n\t  value ?><root/>", Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(pis) == 1
    end

    @testset "PI errors" begin
        # XML.jl is lenient about incomplete PIs without a root element,
        # but these should fail when embedded in a document
        @test_throws Exception parse("<root><?</root>", Node)
        @test_throws Exception parse("<root><?name</root>", Node)
    end

    #==========================================================================#
    #                              Comments                                    #
    #==========================================================================#
    @testset "Comment parsing" begin
        doc = parse("<!----><root/>", Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) == 1
        @test value(comments[1]) == ""

        doc = parse("<!--value--><root/>", Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test value(comments[1]) == "value"

        doc = parse("<root><!--multi\nline\ncomment--></root>", Node)
        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test contains(value(comments[1]), "multi")
    end

    @testset "Comment errors" begin
        @test_throws Exception parse("<!-", Node)
        @test_throws Exception parse("<root><!--</root>", Node)
        @test_throws Exception parse("<!--->", Node)
    end

    #==========================================================================#
    #                              CDATA                                       #
    #==========================================================================#
    @testset "CDATA parsing" begin
        doc = parse("<root><![CDATA[]]></root>", Node)
        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata) == 1
        @test value(cdata[1]) == ""

        doc = parse("<root><![CDATA[value]]></root>", Node)
        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test value(cdata[1]) == "value"

        # CDATA preserves markup characters
        doc = parse("<root><![CDATA[<greeting>Hello!</greeting>]]></root>", Node)
        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test value(cdata[1]) == "<greeting>Hello!</greeting>"
    end

    @testset "CDATA errors" begin
        @test_throws Exception parse("<root><![", Node)
        @test_throws Exception parse("<root><![CDATA[", Node)
        @test_throws Exception parse("<root><![CDATA[data", Node)
    end

    #==========================================================================#
    #                           Tag Parsing                                    #
    #==========================================================================#
    @testset "Self-closing tags" begin
        doc = parse("<node/>", Node)
        @test tag(children(doc)[1]) == "node"

        doc = parse("<node />", Node)
        @test tag(children(doc)[1]) == "node"

        doc = parse("<node\n/>", Node)
        @test tag(children(doc)[1]) == "node"
    end

    @testset "Tag hierarchy" begin
        doc = parse("<node><n1><n2/></n1><n3><n4><n5/></n4></n3></node>", Node)
        root = children(doc)[1]
        @test tag(root) == "node"
        root_els = filter(x -> nodetype(x) == Element, children(root))
        @test length(root_els) == 2
        @test tag(root_els[1]) == "n1"
        @test tag(root_els[2]) == "n3"
    end

    @testset "Tag errors" begin
        @test_throws Exception parse("<", Node)
        @test_throws Exception parse("<node", Node)
        @test_throws Exception parse("<node></nodes>", Node)
        @test_throws Exception parse("<node>", Node)
        @test_throws Exception parse("</node>", Node)
    end

    #==========================================================================#
    #                        Attribute Parsing                                 #
    #==========================================================================#
    @testset "Attribute quotes" begin
        doc = parse("<node id1='v1' id2=\"v2\"/>", Node)
        el = children(doc)[1]
        @test el["id1"] == "v1"
        @test el["id2"] == "v2"
    end

    @testset "Attribute spaces around =" begin
        doc = parse("<node id1='v1' id2 ='v2' id3= 'v3' id4 = 'v4' />", Node)
        el = children(doc)[1]
        @test el["id1"] == "v1"
        @test el["id2"] == "v2"
        @test el["id3"] == "v3"
        @test el["id4"] == "v4"
    end

    @testset "Attribute errors" begin
        @test_throws Exception parse("<node id", Node)
        @test_throws Exception parse("<node id='/>", Node)
        @test_throws Exception parse("<node id='value", Node)
    end

    #==========================================================================#
    #                        Entity/Escape Handling                            #
    #==========================================================================#
    @testset "Predefined entities in attributes" begin
        doc = parse("<node id='&lt;&gt;&amp;&apos;&quot;'/>", Node)
        @test children(doc)[1]["id"] == "<>&'\""
    end

    @testset "Predefined entities in text" begin
        doc = parse("<node>&lt;&gt;&amp;&apos;&quot;</node>", Node)
        @test simple_value(children(doc)[1]) == "<>&'\""
    end

    @testset "Numeric character references" begin
        doc = parse("<node>&#32;&#x20;</node>", Node)
        @test simple_value(children(doc)[1]) == "  "
    end

    @testset "Unicode character references" begin
        # Greek gamma
        doc = parse("<node>&#x03B3;</node>", Node)
        @test simple_value(children(doc)[1]) == "γ"

        # Same char, lowercase hex
        doc = parse("<node>&#x03b3;</node>", Node)
        @test simple_value(children(doc)[1]) == "γ"
    end

    #==========================================================================#
    #                           Whitespace                                     #
    #==========================================================================#
    @testset "Whitespace text nodes preserved" begin
        doc = parse("<root>  <node>  </node>  </root>", Node)
        root = children(doc)[1]
        # Should have text nodes with whitespace
        text_nodes = filter(x -> nodetype(x) == Text, children(root))
        @test length(text_nodes) >= 1
    end

    @testset "PCDATA content" begin
        doc = parse("<root>text content</root>", Node)
        @test simple_value(children(doc)[1]) == "text content"
    end

    #==========================================================================#
    #                        Unicode / CJK Content                             #
    #==========================================================================#
    @testset "Unicode element names (CJK)" begin
        # XML.jl tokenizer does not yet support CJK characters in element/attribute names
        @test_broken try
            parse("<汉语>世界</汉语>", Node)
            true
        catch
            false
        end
    end

    @testset "Unicode text content" begin
        doc = parse("<doc>Ünïcödé café naïve</doc>", Node)
        @test simple_value(children(doc)[1]) == "Ünïcödé café naïve"
    end

    #==========================================================================#
    #                        Mixed Content                                     #
    #==========================================================================#
    @testset "Mixed text, CDATA, comments" begin
        xml = "<node>First text<!-- comment -->Second text<![CDATA[cdata]]>Last text</node>"
        doc = parse(xml, Node)
        root = children(doc)[1]
        child_types = map(nodetype, children(root))
        @test Text in child_types
        @test Comment in child_types
        @test CData in child_types
    end

    #==========================================================================#
    #                        Complex Document                                  #
    #==========================================================================#
    @testset "Complex document with all node types" begin
        xml = """<?xml version="1.0"?>
<!DOCTYPE mesh SYSTEM "mesh.dtd">
<!-- comment in prolog -->
<?custom-pi data?>
<mesh name="mesh_root">
    <!-- inner comment -->
    some text
    <![CDATA[cdata content]]>
    <node attr1="value1" attr2="value2" />
    <node attr1="value2">
        <innernode/>
    </node>
    <?include somedata?>
</mesh>"""
        doc = parse(xml, Node)
        @test nodetype(doc) == Document

        root_els = filter(x -> nodetype(x) == Element, children(doc))
        @test length(root_els) == 1
        mesh = root_els[1]
        @test tag(mesh) == "mesh"
        @test mesh["name"] == "mesh_root"

        # Check inner content types
        inner = children(mesh)
        @test any(x -> nodetype(x) == Comment, inner)
        @test any(x -> nodetype(x) == Text, inner)
        @test any(x -> nodetype(x) == CData, inner)
        @test any(x -> nodetype(x) == ProcessingInstruction, inner)

        nodes = filter(x -> nodetype(x) == Element && tag(x) == "node", inner)
        @test length(nodes) == 2
        @test nodes[1]["attr1"] == "value1"
        @test nodes[1]["attr2"] == "value2"
    end

    #==========================================================================#
    #                             XPath                                        #
    #==========================================================================#
    @testset "XPath" begin
        @testset "descendant with attribute predicate" begin
            doc = parse("<a><b><c id='a'/></b><c id='b'/></a>", Node)
            results = xpath(doc, "//c[@id='b']")
            @test length(results) == 1
            @test results[1]["id"] == "b"
        end

        @testset "child with attribute" begin
            doc = parse("<a><b><c id='a'/></b><c id='b'/></a>", Node)
            results = xpath(doc, "/a/c[@id]")
            @test length(results) == 1
            @test results[1]["id"] == "b"
        end

        @testset "wildcard with attribute predicate" begin
            doc = parse("""<node><child1 attr1="v1" attr2="v2"/><child2 attr1="v1">test</child2></node>""", Node)
            results = xpath(doc, "/node/*[@attr1]")
            @test length(results) == 2
        end

        @testset "descendant-or-self with text()" begin
            doc = parse("<a><b><c><d><e>deep</e></d></c></b></a>", Node)
            results = xpath(doc, "//e/text()")
            @test length(results) == 1
            @test value(results[1]) == "deep"
        end

        @testset "positional predicate" begin
            doc = parse("<root><a/><b/><c/></root>", Node)
            results = xpath(doc, "/root/*[1]")
            @test length(results) == 1
            @test tag(results[1]) == "a"

            results = xpath(doc, "/root/*[last()]")
            @test length(results) == 1
            @test tag(results[1]) == "c"
        end

        @testset "nested predicates" begin
            doc = parse("""<node><child><subchild id="1"/></child><child><subchild id="2"/></child></node>""", Node)
            results = xpath(doc, "//subchild[@id]")
            @test length(results) == 2
        end
    end
end
