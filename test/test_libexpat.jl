# Test cases inspired by libexpat (https://github.com/libexpat/libexpat, MIT license)
# Translated from expat/tests/basic_tests.c

using XML
using XML: Node, nodetype, Document, Element, Comment, CData, ProcessingInstruction, Text, Declaration, DTD
using XML: tag, value, children, attributes, simple_value
using Test

@testset "libexpat-inspired" begin

    #==========================================================================#
    #                         Character References                             #
    #==========================================================================#
    @testset "Decimal character references" begin
        doc = parse("<doc>&#233;&#232;</doc>", Node)
        @test simple_value(children(doc)[1]) == "éè"
    end

    @testset "Hex character references" begin
        doc = parse("<doc>&#xE9;&#xE8;</doc>", Node)
        @test simple_value(children(doc)[1]) == "éè"
    end

    @testset "Mixed char refs and text" begin
        doc = parse("<doc>abc&#100;ef</doc>", Node)
        @test simple_value(children(doc)[1]) == "abcdef"
    end

    @testset "Large Unicode code points" begin
        # CJK Unified Ideograph
        doc = parse("<doc>&#x4E16;&#x754C;</doc>", Node)
        @test simple_value(children(doc)[1]) == "世界"
    end

    #==========================================================================#
    #                          UTF-8 Content                                   #
    #==========================================================================#
    @testset "UTF-8 BOM" begin
        bom = "\xef\xbb\xbf"
        doc = parse(bom * "<e/>", Node)
        @test nodetype(doc) == Document
    end

    @testset "UTF-8 element content" begin
        doc = parse("<doc>Ünïcödé</doc>", Node)
        @test simple_value(children(doc)[1]) == "Ünïcödé"
    end

    @testset "UTF-8 in attribute values" begin
        doc = parse("<doc attr='café'/>", Node)
        @test children(doc)[1]["attr"] == "café"
    end

    @testset "UTF-8 element names" begin
        # XML.jl tokenizer does not yet support non-ASCII characters in element names
        @test_broken try
            parse("<données/>", Node)
            true
        catch
            false
        end
    end

    @testset "Multi-byte UTF-8 sequences" begin
        # 2-byte: ñ (U+00F1)
        doc = parse("<doc>ñ</doc>", Node)
        @test simple_value(children(doc)[1]) == "ñ"

        # 3-byte: 世 (U+4E16)
        doc = parse("<doc>世</doc>", Node)
        @test simple_value(children(doc)[1]) == "世"

        # 4-byte: 𤭢 (U+24B62)
        doc = parse("<doc>𤭢</doc>", Node)
        @test simple_value(children(doc)[1]) == "𤭢"
    end

    #==========================================================================#
    #                            CDATA                                         #
    #==========================================================================#
    @testset "Basic CDATA" begin
        doc = parse("<a><![CDATA[<greeting>Hello!</greeting>]]></a>", Node)
        root = children(doc)[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata) == 1
        @test value(cdata[1]) == "<greeting>Hello!</greeting>"
    end

    @testset "CDATA with special characters" begin
        doc = parse("<a><![CDATA[&<>\"']]></a>", Node)
        root = children(doc)[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test value(cdata[1]) == "&<>\"'"
    end

    @testset "Multiple CDATA sections" begin
        doc = parse("<a><![CDATA[first]]><![CDATA[second]]></a>", Node)
        root = children(doc)[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata) == 2
        @test value(cdata[1]) == "first"
        @test value(cdata[2]) == "second"
    end

    @testset "CDATA containing ]]" begin
        # ]] without > is valid inside CDATA
        doc = parse("<a><![CDATA[data]]with]]brackets]]></a>", Node)
        root = children(doc)[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test value(cdata[1]) == "data]]with]]brackets"
    end

    @testset "CDATA errors" begin
        @test_throws Exception parse("<a><![CDATA[no end", Node)
        @test_throws Exception parse("<a><![CDATA[", Node)
    end

    #==========================================================================#
    #                          XML Declaration                                 #
    #==========================================================================#
    @testset "XML declaration" begin
        doc = parse("<?xml version='1.0'?><doc/>", Node)
        decls = filter(x -> nodetype(x) == Declaration, children(doc))
        @test length(decls) == 1
        @test decls[1]["version"] == "1.0"
    end

    @testset "XML declaration with encoding" begin
        doc = parse("<?xml version='1.0' encoding='UTF-8'?><doc/>", Node)
        decls = filter(x -> nodetype(x) == Declaration, children(doc))
        @test decls[1]["encoding"] == "UTF-8"
    end

    @testset "XML declaration with standalone" begin
        doc = parse("<?xml version='1.0' standalone='yes'?><doc/>", Node)
        decls = filter(x -> nodetype(x) == Declaration, children(doc))
        @test decls[1]["standalone"] == "yes"
    end

    @testset "Full XML declaration" begin
        doc = parse("<?xml version='1.0' encoding='UTF-8' standalone='no'?><doc/>", Node)
        decls = filter(x -> nodetype(x) == Declaration, children(doc))
        @test decls[1]["version"] == "1.0"
        @test decls[1]["encoding"] == "UTF-8"
        @test decls[1]["standalone"] == "no"
    end

    #==========================================================================#
    #                        Processing Instructions                           #
    #==========================================================================#
    @testset "Processing instructions" begin
        doc = parse("<?mypi data?><doc/>", Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(pis) == 1

        doc = parse("<doc><?inner-pi some data?></doc>", Node)
        root = children(doc)[1]
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(root))
        @test length(pis) == 1
    end

    @testset "PI with no data" begin
        doc = parse("<?mypi?><doc/>", Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(pis) == 1
    end

    #==========================================================================#
    #                           Comments                                       #
    #==========================================================================#
    @testset "Comments in various positions" begin
        # In prolog
        doc = parse("<!-- prolog comment --><doc/>", Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) == 1

        # Inside element
        doc = parse("<doc><!-- inner --></doc>", Node)
        root = children(doc)[1]
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test length(comments) == 1

        # After root element
        doc = parse("<doc/><!-- epilog -->", Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) == 1
    end

    @testset "Comment with special content" begin
        doc = parse("<doc><!-- <not-an-element> &not-entity; --></doc>", Node)
        root = children(doc)[1]
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test contains(value(comments[1]), "<not-an-element>")
        @test contains(value(comments[1]), "&not-entity;")
    end

    #==========================================================================#
    #                          DTD / DOCTYPE                                    #
    #==========================================================================#
    @testset "DOCTYPE with internal subset" begin
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (#PCDATA)>
<!ATTLIST doc attr CDATA #IMPLIED>
]>
<doc attr="value">text</doc>"""
        doc = parse(xml, Node)
        @test nodetype(doc) == Document
        dtd_nodes = filter(x -> nodetype(x) == DTD, children(doc))
        @test length(dtd_nodes) == 1
        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        @test tag(root) == "doc"
        @test root["attr"] == "value"
        text_nodes = filter(x -> nodetype(x) == Text, children(root))
        @test length(text_nodes) == 1
        @test value(text_nodes[1]) == "text"
    end

    @testset "DOCTYPE with SYSTEM" begin
        doc = parse("<!DOCTYPE doc SYSTEM 'test.dtd'><doc/>", Node)
        dtd_nodes = filter(x -> nodetype(x) == DTD, children(doc))
        @test length(dtd_nodes) == 1
    end

    @testset "DOCTYPE with PUBLIC" begin
        doc = parse("""<!DOCTYPE doc PUBLIC "-//Test//DTD Test//EN" "test.dtd"><doc/>""", Node)
        dtd_nodes = filter(x -> nodetype(x) == DTD, children(doc))
        @test length(dtd_nodes) == 1
    end

    #==========================================================================#
    #                         Entity Handling                                  #
    #==========================================================================#
    @testset "Predefined entities" begin
        doc = parse("<doc>&lt;&gt;&amp;&apos;&quot;</doc>", Node)
        @test simple_value(children(doc)[1]) == "<>&'\""
    end

    @testset "Entities in attribute values" begin
        doc = parse("<doc attr='&lt;value&gt;'/>", Node)
        @test children(doc)[1]["attr"] == "<value>"
    end

    @testset "Mixed entities and text" begin
        doc = parse("<doc>Hello &amp; welcome &lt;user&gt;</doc>", Node)
        @test simple_value(children(doc)[1]) == "Hello & welcome <user>"
    end

    #==========================================================================#
    #                        Attribute Edge Cases                              #
    #==========================================================================#
    @testset "Empty attribute value" begin
        doc = parse("<doc attr=''/>", Node)
        @test children(doc)[1]["attr"] == ""

        doc = parse("""<doc attr=""/>""", Node)
        @test children(doc)[1]["attr"] == ""
    end

    @testset "Attribute with entities" begin
        doc = parse("<doc attr='a&amp;b'/>", Node)
        @test children(doc)[1]["attr"] == "a&b"
    end

    @testset "Multiple attributes" begin
        doc = parse("""<doc a="1" b="2" c="3" d="4" e="5"/>""", Node)
        el = children(doc)[1]
        @test el["a"] == "1"
        @test el["b"] == "2"
        @test el["c"] == "3"
        @test el["d"] == "4"
        @test el["e"] == "5"
    end

    @testset "Attribute error: duplicate" begin
        @test_throws Exception parse("""<doc attr="1" attr="2"/>""", Node)
    end

    #==========================================================================#
    #                        Nesting & Structure                               #
    #==========================================================================#
    @testset "Deeply nested elements" begin
        xml = "<a><b><c><d><e><f><g><h><i><j>deep</j></i></h></g></f></e></d></c></b></a>"
        doc = parse(xml, Node)
        @test nodetype(doc) == Document
    end

    @testset "Many sibling elements" begin
        items = join(["<item>$i</item>" for i in 1:100])
        xml = "<root>$items</root>"
        doc = parse(xml, Node)
        root = children(doc)[1]
        els = filter(x -> nodetype(x) == Element, children(root))
        @test length(els) == 100
        @test simple_value(els[1]) == "1"
        @test simple_value(els[100]) == "100"
    end

    @testset "Mismatched tags" begin
        @test_throws Exception parse("<a></b>", Node)
        @test_throws Exception parse("<a><b></a></b>", Node)
        @test_throws Exception parse("<a><b><c></b></c></a>", Node)
    end

    @testset "Unclosed elements" begin
        @test_throws Exception parse("<a><b>", Node)
        @test_throws Exception parse("<a>text", Node)
    end

    #==========================================================================#
    #                           Line Endings                                   #
    #==========================================================================#
    @testset "Various line endings in content" begin
        # CR, LF, CRLF should all work
        doc = parse("<doc>line1\nline2</doc>", Node)
        @test nodetype(doc) == Document

        doc = parse("<doc>line1\rline2</doc>", Node)
        @test nodetype(doc) == Document

        doc = parse("<doc>line1\r\nline2</doc>", Node)
        @test nodetype(doc) == Document
    end

    #==========================================================================#
    #                          Empty Document Parts                            #
    #==========================================================================#
    @testset "Empty root element" begin
        doc = parse("<doc/>", Node)
        root = children(doc)[1]
        @test tag(root) == "doc"
        @test isempty(filter(x -> nodetype(x) == Element, children(root)))
    end

    @testset "Element with only whitespace" begin
        doc = parse("<doc>   \n\t  </doc>", Node)
        @test nodetype(doc) == Document
    end

    @testset "Element with only comments" begin
        doc = parse("<doc><!-- c1 --><!-- c2 --></doc>", Node)
        root = children(doc)[1]
        els = filter(x -> nodetype(x) == Element, children(root))
        @test isempty(els)
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test length(comments) == 2
    end

    #==========================================================================#
    #                       Namespace-like Attributes                          #
    #==========================================================================#
    @testset "xmlns declarations" begin
        doc = parse("""<doc xmlns="http://example.com" xmlns:ns="http://example.com/ns"><ns:child/></doc>""", Node)
        root = children(doc)[1]
        @test root["xmlns"] == "http://example.com"
        @test root["xmlns:ns"] == "http://example.com/ns"
        els = filter(x -> nodetype(x) == Element, children(root))
        @test tag(els[1]) == "ns:child"
    end

    @testset "Namespaced attributes" begin
        doc = parse("""<doc xml:lang="en" xml:space="preserve"/>""", Node)
        root = children(doc)[1]
        @test root["xml:lang"] == "en"
        @test root["xml:space"] == "preserve"
    end

    #==========================================================================#
    #                        Large Content                                     #
    #==========================================================================#
    @testset "Long attribute value" begin
        long_val = repeat("x", 10_000)
        doc = parse("<doc attr='$long_val'/>", Node)
        @test children(doc)[1]["attr"] == long_val
    end

    @testset "Long text content" begin
        long_text = repeat("Hello World! ", 1000)
        doc = parse("<doc>$long_text</doc>", Node)
        @test simple_value(children(doc)[1]) == long_text
    end

    @testset "Long CDATA" begin
        long_cdata = repeat("data<>& ", 1000)
        doc = parse("<doc><![CDATA[$long_cdata]]></doc>", Node)
        root = children(doc)[1]
        cdata = filter(x -> nodetype(x) == CData, children(root))
        @test value(cdata[1]) == long_cdata
    end
end
