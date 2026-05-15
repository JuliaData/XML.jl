# Test cases borrowed from the libxml2 test suite (https://github.com/GNOME/libxml2).
#
# libxml2 is Copyright (C) the GNOME Project and contributors, licensed under the MIT License.
# These test cases are adapted for the XML.jl Julia package.
#
# Categories mirror the libxml2 test/ directory structure:
#   - CDATA handling
#   - Comments
#   - Processing instructions
#   - Attributes (normalization, entities, quoting)
#   - Namespaces
#   - DTD / internal subset
#   - Entity references (character refs, predefined, internal general)
#   - Whitespace / blank handling
#   - Well-formedness (boundaries, big names, mixed content)
#   - Error cases (must fail to parse)

using XML
using XML: Document, Element, Declaration, Comment, CData, DTD, ProcessingInstruction, Text
using XML: escape, unescape
using Test

@testset "libxml2 test cases" begin

#==============================================================================#
#                            CDATA SECTIONS                                    #
#   From: test/cdata, test/cdata2, test/adjacent-cdata.xml,                   #
#         test/emptycdata.xml, test/cdata-*-byte-UTF-8.xml                    #
#==============================================================================#
@testset "CDATA" begin
    @testset "cdata: basic CDATA with markup characters" begin
        # libxml2 test/cdata
        xml = """<doc>\n<![CDATA[<greeting>Hello, world!</greeting>]]>\n</doc>"""
        doc = parse(xml, Node)
        root = doc[1]
        cdata_nodes = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata_nodes) >= 1
        @test value(cdata_nodes[1]) == "<greeting>Hello, world!</greeting>"
    end

    @testset "cdata2: nested CDATA-like content" begin
        # libxml2 test/cdata2 - tests ]]> escaping pattern
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<collection>
  <test><![CDATA[
    <![CDATA[abc]]]>]&gt;<![CDATA[
  ]]></test>
</collection>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "collection"
    end

    @testset "adjacent-cdata: three adjacent CDATA sections" begin
        # libxml2 test/adjacent-cdata.xml
        xml = "<doc><![CDATA[abc]]><![CDATA[def]]><![CDATA[ghi]]></doc>"
        doc = parse(xml, Node)
        root = doc[1]
        cdata_nodes = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata_nodes) == 3
        @test value(cdata_nodes[1]) == "abc"
        @test value(cdata_nodes[2]) == "def"
        @test value(cdata_nodes[3]) == "ghi"
    end

    @testset "emptycdata: empty CDATA section in namespaced doc" begin
        # libxml2 test/emptycdata.xml
        xml = """<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<![CDATA[]]>
</html>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "html"
        cdata_nodes = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata_nodes) >= 1
        @test value(cdata_nodes[1]) == ""
    end

    @testset "cdata-2-byte-UTF-8: two-byte chars across buffer boundary" begin
        # libxml2 test/cdata-2-byte-UTF-8.xml - tests Č (U+010C, 2 bytes in UTF-8)
        long_c = repeat("Č", 400)
        xml = """<?xml version="1.0" encoding="UTF-8"?>\n<doc>\n<p><![CDATA[$(long_c)]]></p>\n</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        p = first(filter(x -> nodetype(x) == Element, children(root)))
        cdata = first(filter(x -> nodetype(x) == CData, children(p)))
        @test value(cdata) == long_c
    end

    @testset "cdata-3-byte-UTF-8: three-byte chars across buffer boundary" begin
        # libxml2 test/cdata-3-byte-UTF-8.xml - tests 牛 (U+725B, 3 bytes in UTF-8)
        long_cow = repeat("牛", 400)
        xml = """<?xml version="1.0" encoding="UTF-8"?>\n<doc>\n<p><![CDATA[$(long_cow)]]></p>\n</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        p = first(filter(x -> nodetype(x) == Element, children(root)))
        cdata = first(filter(x -> nodetype(x) == CData, children(p)))
        @test value(cdata) == long_cow
    end

    @testset "cdata-4-byte-UTF-8: four-byte chars across buffer boundary" begin
        # libxml2 test/cdata-4-byte-UTF-8.xml - tests 🍦 (U+1F366, 4 bytes in UTF-8)
        long_ice = repeat("🍦", 334)
        xml = """<?xml version="1.0" encoding="UTF-8"?>\n<doc>\n<p><![CDATA[$(long_ice)]]></p>\n</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        p = first(filter(x -> nodetype(x) == Element, children(root)))
        cdata = first(filter(x -> nodetype(x) == CData, children(p)))
        @test value(cdata) == long_ice
    end
end

#==============================================================================#
#                              COMMENTS                                        #
#   From: test/comment.xml through test/comment6.xml, test/badcomment.xml      #
#==============================================================================#
@testset "Comments" begin
    @testset "comment: comments inside element" begin
        # libxml2 test/comment.xml
        xml = """<?xml version="1.0"?>
<doc>
<!-- document start -->
<empty/>
<!-- document end -->
</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test length(comments) == 2
        @test contains(value(comments[1]), "document start")
        @test contains(value(comments[2]), "document end")
    end

    @testset "comment2: comments outside root element" begin
        # libxml2 test/comment2.xml
        xml = """<?xml version="1.0"?>
<!-- document start -->
<doc>
<empty/>
</doc>
<!-- document end -->"""
        doc = parse(xml, Node)
        top_comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(top_comments) == 2
        @test contains(value(top_comments[1]), "document start")
        @test contains(value(top_comments[2]), "document end")
    end

    @testset "comment3: very long comment (buffer boundary test)" begin
        # libxml2 test/comment3.xml - 150+ lines of repeated digits
        lines = join([repeat("01234567890123456789012345678901234567890123456789", 1) for _ in 1:150], "\n")
        comment_text = " test of very very long comments and buffer limits\n" * lines * "\n"
        xml = """<?xml version="1.0"?>\n<!--$(comment_text)-->\n<doc/>"""
        doc = parse(xml, Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) >= 1
        @test length(value(comments[1])) > 7000
    end

    @testset "comment5: hyphens and line breaks in comments" begin
        # libxml2 test/comment5.xml
        xml = """<?xml version="1.0"?>
<!-- test of hyphen and line break handling
     some text - interrupted -
- - - - - - - - - - - - - - - - - - - - - -
                      this should stop here^


-->
<doc/>"""
        doc = parse(xml, Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) == 1
        @test contains(value(comments[1]), "hyphen")
        @test contains(value(comments[1]), "- - -")
    end

    @testset "comment6: comment before DOCTYPE" begin
        # libxml2 test/comment6.xml
        xml = """<!--
long comment long comment long comment long comment long comment long comment
long comment long comment long comment long comment long comment long comment
long comment long comment long comment long comment long comment long comment
-->
<!DOCTYPE a [
<!ELEMENT a EMPTY>
]>
<a/>"""
        doc = parse(xml, Node)
        typed = filter(x -> nodetype(x) != Text, children(doc))
        @test nodetype(typed[1]) == Comment
        @test nodetype(typed[2]) == DTD
        @test nodetype(typed[3]) == Element
    end

    @testset "badcomment: comment with markup-like content" begin
        # libxml2 test/badcomment.xml - note: libxml2 considers this valid XML
        xml = """<?xml version="1.0" encoding="UTF-8"?>

<foo>
<!-- def='NT-Char'-->
</foo>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "foo"
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test length(comments) >= 1
    end

    @testset "comment4: non-ASCII characters in comments" begin
        # libxml2 test/comment4.xml (adapted from ISO-8859-1 to UTF-8)
        xml = """<?xml version="1.0"?>
<!-- test of non ascii comments like là et très -->
<!--à another one -->
<!-- another one à-->
<doc/>"""
        doc = parse(xml, Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc))
        @test length(comments) == 3
        @test contains(value(comments[1]), "là")
        @test contains(value(comments[2]), "à")
    end
end

#==============================================================================#
#                        PROCESSING INSTRUCTIONS                               #
#   From: test/pi.xml, test/pi2.xml                                           #
#==============================================================================#
@testset "Processing Instructions" begin
    @testset "pi: PIs inside root element" begin
        # libxml2 test/pi.xml
        xml = """<?xml version="1.0"?>
<doc>
<?document-start doc?>
<empty/>
<?document-end doc?>
</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(root))
        @test length(pis) == 2
        @test tag(pis[1]) == "document-start"
        @test value(pis[1]) == "doc"
        @test tag(pis[2]) == "document-end"
        @test value(pis[2]) == "doc"
    end

    @testset "pi2: PIs outside root element" begin
        # libxml2 test/pi2.xml
        xml = """<?xml version="1.0"?>
<?document-start doc?>
<doc>
<empty/>
</doc>
<?document-end doc?>"""
        doc = parse(xml, Node)
        top_pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc))
        @test length(top_pis) == 2
        @test tag(top_pis[1]) == "document-start"
        @test tag(top_pis[2]) == "document-end"
    end
end

#==============================================================================#
#                            ATTRIBUTES                                        #
#   From: test/att1 through test/att11, test/attrib.xml,                       #
#         test/def-xml-attr.xml, test/defattr.xml                              #
#==============================================================================#
@testset "Attributes" begin
    @testset "att1: attribute with newlines (whitespace normalization)" begin
        # libxml2 test/att1
        xml = "<doc attr=\"to normalize\nwith a    space\"/>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == "doc"
        @test haskey(doc[1], "attr")
    end

    @testset "att2: attribute with multiple spaces" begin
        # libxml2 test/att2
        xml = """<doc attr="to normalize  with a space"/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "to normalize  with a space"
    end

    @testset "att3: attribute with character references" begin
        # libxml2 test/att3
        xml = """<select onclick="aaaa&#10;      bbbb&#160;">f&#160;oo</select>"""
        doc = parse(xml, Node)
        @test tag(doc[1]) == "select"
        @test haskey(doc[1], "onclick")
    end

    @testset "att4: complex document with many attributes" begin
        # Adapted from libxml2 test/att4 (electroxml document)
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<electroxml modified="20021216T072726">
  <data from="20021031T22" to="20021130T22">
    <select>
      <device serialnumb="E00003562">
        <par memind="113400" h="3dc1a8de">
          <val o="0" v="53"/>
          <val o="e08" v="53"/>
        </par>
      </device>
    </select>
  </data>
</electroxml>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "electroxml"
        @test root["modified"] == "20021216T072726"
    end

    @testset "attrib: attribute with entities and char refs" begin
        # libxml2 test/attrib.xml
        xml = """<item title="Warning: &apos;test&apos;&#160;&#160;" url="http://example.com/" first_time="985034339" visits="1"/>"""
        doc = parse(xml, Node)
        @test tag(doc[1]) == "item"
        @test doc[1]["url"] == "http://example.com/"
        @test doc[1]["visits"] == "1"
    end

    @testset "att5: attribute with empty value" begin
        # Adapted from libxml2 test/att5
        xml = """<?xml version="1.0"?>
<doc a="" b="val"/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test root["a"] == ""
        @test root["b"] == "val"
    end

    @testset "att9: attribute with single quotes in double-quoted value" begin
        # libxml2 test/att9 pattern
        xml = """<doc attr="it's a test"/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "it's a test"
    end

    @testset "att10: attribute with double quotes in single-quoted value" begin
        xml = """<doc attr='he said "hello"'/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "he said \"hello\""
    end

    @testset "att11: attribute values with entity refs" begin
        xml = """<doc a="&lt;tag&gt;" b="a&amp;b"/>"""
        doc = parse(xml, Node)
        @test doc[1]["a"] == "<tag>"
        @test doc[1]["b"] == "a&b"
    end

    @testset "def-xml-attr: xml:lang default attribute in DTD" begin
        # libxml2 test/def-xml-attr.xml (just verify parsing doesn't fail)
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE root [
  <!ATTLIST foo xml:lang CDATA "eng">
  <!ATTLIST foo bar CDATA "&lt;&gt;&quot;">
]>
<root>
  <foo/>
</root>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "root"
    end
end

#==============================================================================#
#                            NAMESPACES                                        #
#   From: test/ns through test/ns7, test/namespaces/err_*.xml,                #
#         test/nsclean.xml, test/entity-in-ns-uri.xml                          #
#==============================================================================#
@testset "Namespaces" begin
    @testset "ns: namespace with prefix on element and attribute" begin
        # libxml2 test/ns
        xml = """<?xml version="1.0"?>
<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/">
  <dia:diagramdata dia:testattr="test"/>
</dia:diagram>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "dia:diagram"
        @test root["xmlns:dia"] == "http://www.lysator.liu.se/~alla/dia/"
        child = first(filter(x -> nodetype(x) == Element, children(root)))
        @test tag(child) == "dia:diagramdata"
        @test child["dia:testattr"] == "test"
    end

    @testset "ns2: namespace on self-closing element" begin
        # libxml2 test/ns2
        xml = """<?xml version="1.0"?>
<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/"
             dia:testattr="test"/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "dia:diagram"
        @test root["dia:testattr"] == "test"
    end

    @testset "ns3: xmlns declared after prefixed attribute" begin
        # libxml2 test/ns3
        xml = """<?xml version="1.0"?>
<dia:diagram dia:testattr="test"
             xmlns:dia="http://www.lysator.liu.se/~alla/dia/"/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test root["dia:testattr"] == "test"
        @test root["xmlns:dia"] == "http://www.lysator.liu.se/~alla/dia/"
    end

    @testset "ns4: xml:lang, xml:link, xml:space built-in attributes" begin
        # libxml2 test/ns4
        xml = """<?xml version="1.0"?>
<diagram testattr="test" xml:lang="en" xml:link="simple" xml:space="preserve"/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test root["xml:lang"] == "en"
        @test root["xml:space"] == "preserve"
    end

    @testset "ns5: default namespace on element with prefix on another" begin
        # libxml2 test/ns5
        xml = """<element name="foo" xmlns:rng="http://example.org/ns/1" xmlns="http://example.org/ns/1">
  <empty/>
</element>"""
        doc = parse(xml, Node)
        root = doc[1]
        @test root["xmlns"] == "http://example.org/ns/1"
        @test root["xmlns:rng"] == "http://example.org/ns/1"
        @test root["name"] == "foo"
    end

    @testset "ns6: default namespace on child, not on sibling" begin
        # libxml2 test/ns6
        xml = """<root>
  <foo xmlns="http://abc" />
  <bar />
</root>"""
        doc = parse(xml, Node)
        root = doc[1]
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test tag(elements[1]) == "foo"
        @test elements[1]["xmlns"] == "http://abc"
        @test tag(elements[2]) == "bar"
    end

    @testset "ns7: xml: prefix element (built-in)" begin
        # libxml2 test/ns7
        xml = "<xml:test/>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == "xml:test"
    end

    @testset "multiple namespace prefixes" begin
        xml = """<root xmlns:a="http://a.com" xmlns:b="http://b.com">
  <a:child a:attr="1"/>
  <b:child b:attr="2"/>
</root>"""
        doc = parse(xml, Node)
        root = doc[1]
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test tag(elements[1]) == "a:child"
        @test elements[1]["a:attr"] == "1"
        @test tag(elements[2]) == "b:child"
        @test elements[2]["b:attr"] == "2"
    end

    @testset "namespace redeclaration on nested element" begin
        xml = """<root xmlns:a="http://first.com">
  <child xmlns:a="http://second.com">
    <a:leaf/>
  </child>
</root>"""
        doc = parse(xml, Node)
        root = doc[1]
        child = first(filter(x -> nodetype(x) == Element, children(root)))
        @test child["xmlns:a"] == "http://second.com"
    end
end

#==============================================================================#
#                    DTD / INTERNAL SUBSET                                     #
#   From: test/dtd1 through test/dtd13, test/intsubset.xml,                   #
#         test/intsubset2.xml                                                  #
#==============================================================================#
@testset "DTD / Internal Subset" begin
    @testset "dtd1: DOCTYPE with PUBLIC id" begin
        # libxml2 test/dtd1
        xml = """<?xml version="1.0"?>
<!DOCTYPE MEMO PUBLIC "-//SGMLSOURCE//DTD MEMO//EN"
                      "http://www.sgmlsource.com/dtds/memo.dtd">
<MEMO>
</MEMO>"""
        doc = parse(xml, Node)
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test contains(value(dtd), "MEMO")
        @test contains(value(dtd), "PUBLIC")
    end

    @testset "dtd2: simple internal subset with ELEMENT declaration" begin
        # libxml2 test/dtd2
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (#PCDATA)>
]>
<doc>This is a valid document !</doc>"""
        doc = parse(xml, Node)
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test contains(value(dtd), "ELEMENT")
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test simple_value(root) == "This is a valid document !"
    end

    @testset "dtd3: ANY content model" begin
        # libxml2 test/dtd3
        xml = """<!DOCTYPE doc [
<!ELEMENT doc ANY>
]>
<doc>This is a valid document !</doc>"""
        doc = parse(xml, Node)
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test contains(value(dtd), "ANY")
    end

    @testset "dtd4: EMPTY content model" begin
        # libxml2 test/dtd4
        xml = """<?xml version="1.0"?>
<!DOCTYPE doc [
<!ELEMENT doc EMPTY>]>
<doc/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
        @test length(children(root)) == 0
    end

    @testset "dtd5: mixed content model" begin
        # libxml2 test/dtd5
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (#PCDATA | a | b)*>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
]>
<doc><a>This</a> is a <b>valid</b> document</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(elements) == 2
        @test tag(elements[1]) == "a"
        @test tag(elements[2]) == "b"
    end

    @testset "dtd6: choice content model" begin
        # libxml2 test/dtd6
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (a | b)*>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
]>
<doc><a>This</a><b> is a valid</b><a> document</a></doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(elements) == 3
    end

    @testset "dtd7: sequence content model" begin
        # libxml2 test/dtd7
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (a , b)*>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
]>
<doc><a>This</a><b> is a valid document</b></doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(elements) == 2
        @test tag(elements[1]) == "a"
        @test tag(elements[2]) == "b"
    end

    @testset "dtd8: nested choice and sequence" begin
        # libxml2 test/dtd8
        xml = """<!DOCTYPE doc [
<!ELEMENT doc ((a | b) , (c | d))+>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
<!ELEMENT c (#PCDATA)>
<!ELEMENT d (#PCDATA)>
]>
<doc><b>This</b><c> is a valid document</c></doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test tag(elements[1]) == "b"
        @test tag(elements[2]) == "c"
    end

    @testset "dtd9: optional content model" begin
        # libxml2 test/dtd9
        xml = """<!DOCTYPE doc [
<!ELEMENT doc ((a | b | c) , d)?>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
<!ELEMENT c (#PCDATA)>
<!ELEMENT d (#PCDATA)>
]>
<doc><b>This</b><d> is a valid document</d></doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(elements) == 2
    end

    @testset "dtd10: mixed repetition content model" begin
        # libxml2 test/dtd10
        xml = """<!DOCTYPE doc [
<!ELEMENT doc ((a | b)+ , c ,  d)*>
<!ELEMENT a (#PCDATA)>
<!ELEMENT b (#PCDATA)>
<!ELEMENT c (#PCDATA)>
<!ELEMENT d (#PCDATA)>
]>
<doc><b>This</b><c> is a</c><d> valid document</d></doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(elements) == 3
    end

    @testset "dtd11: ATTLIST with CDATA #IMPLIED" begin
        # libxml2 test/dtd11
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (#PCDATA)>
<!ATTLIST doc val CDATA #IMPLIED>
]>
<doc val="v1"/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test root["val"] == "v1"
    end

    @testset "dtd12: nested entity references" begin
        # libxml2 test/dtd12 - entity referencing another entity
        xml = """<!DOCTYPE doc [
<!ENTITY YN '"Yes"' >
<!ENTITY WhatHeSaid "He said &YN;" >
]>
<doc>&WhatHeSaid;</doc>"""
        # This may or may not expand depending on XML.jl's entity handling
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
    end

    @testset "dtd13: comments before and after DOCTYPE" begin
        # libxml2 test/dtd13
        xml = """<!-- comment before the DTD -->
<!DOCTYPE doc [
<!ELEMENT doc ANY>
]>
<!-- comment after the DTD -->
<doc/>"""
        doc = parse(xml, Node)
        typed = filter(x -> nodetype(x) != Text, children(doc))
        @test nodetype(typed[1]) == Comment
        @test nodetype(typed[2]) == DTD
        @test nodetype(typed[3]) == Comment
        @test nodetype(typed[4]) == Element
    end

    @testset "intsubset: internal subset with comment containing quote" begin
        # libxml2 test/intsubset.xml
        xml = """<?xml version="1.0" standalone="yes"?>
<!DOCTYPE root [
<!ELEMENT root  EMPTY>
<!--  " -->
]>
<root/>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "root"
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test contains(value(dtd), "ELEMENT")
    end
end

#==============================================================================#
#                        ENTITY REFERENCES                                     #
#   From: test/ent1 through test/ent11, test/ent6hex                           #
#==============================================================================#
@testset "Entity References" begin
    @testset "ent1: internal general entity declaration and use" begin
        # libxml2 test/ent1
        xml = """<?xml version="1.0"?>
<!DOCTYPE EXAMPLE SYSTEM "example.dtd" [
<!ENTITY xml "Extensible Markup Language">
]>
<EXAMPLE>
    &xml;
</EXAMPLE>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "EXAMPLE"
    end

    @testset "ent3: entity refs in attribute values" begin
        # libxml2 test/ent3
        xml = """<?xml version="1.0"?>
<!DOCTYPE EXAMPLE SYSTEM "example.dtd" [
<!ENTITY xml "Extensible Markup Language">
]>
<EXAMPLE prop1="a&amp;b" prop2="c&lt;d">
</EXAMPLE>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test root["prop1"] == "a&b"
        @test root["prop2"] == "c<d"
    end

    @testset "ent5: numeric character references (decimal and hex)" begin
        # libxml2 test/ent5
        xml = """<?xml version="1.0"?>
<EXAMPLE>
    This is an inverted exclamation sign &#xA1;
    This is a space &#32;
</EXAMPLE>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        text = join([value(c) for c in children(root) if nodetype(c) == Text])
        @test contains(text, "\u00A1")  # ¡
        @test contains(text, " ")       # space (&#32;)
    end

    @testset "ent6: predefined entities with double-escaping" begin
        # libxml2 test/ent6
        xml = """<!DOCTYPE doc [
<!ENTITY lt     "&#38;#60;">
<!ENTITY gt     "&#62;">
<!ENTITY amp    "&#38;#38;">
<!ENTITY apos   "&#39;">
<!ENTITY quot   "&#34;">
]>
<doc a="&lt;">&lt;</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
    end

    @testset "ent8: multiple entities in one document" begin
        # libxml2 test/ent8
        xml = """<!DOCTYPE doc [
<!ENTITY test1 "test 1">
<!ENTITY test2 "test 2">
]>
<doc>
&test1;&test2;
</doc>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
    end

    @testset "predefined entities in text content" begin
        xml = "<doc>&amp; &lt; &gt; &apos; &quot;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "& < > ' \""
    end

    @testset "predefined entities in attributes" begin
        xml = """<doc a="&amp;" b="&lt;" c="&gt;" d="&apos;" e="&quot;"/>"""
        doc = parse(xml, Node)
        @test doc[1]["a"] == "&"
        @test doc[1]["b"] == "<"
        @test doc[1]["c"] == ">"
        @test doc[1]["d"] == "'"
        @test doc[1]["e"] == "\""
    end

    @testset "decimal character references" begin
        xml = "<doc>&#65;&#66;&#67;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "ABC"
    end

    @testset "hexadecimal character references" begin
        xml = "<doc>&#x41;&#x42;&#x43;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "ABC"
    end

    @testset "mixed hex and decimal char refs" begin
        xml = "<doc>&#x48;&#101;&#x6C;&#108;&#x6F;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "Hello"
    end

    @testset "char ref for non-ASCII: inverted exclamation" begin
        xml = "<doc>&#xA1;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "\u00A1"
    end

    @testset "char ref for CJK character" begin
        xml = "<doc>&#x4E2D;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "中"
    end

    @testset "char ref for emoji" begin
        xml = "<doc>&#x1F600;</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "\U0001F600"
    end
end

#==============================================================================#
#                     WHITESPACE / BLANK HANDLING                              #
#   From: test/tstblanks.xml, test/title.xml                                  #
#==============================================================================#
@testset "Whitespace / Blank Handling" begin
    @testset "title: simple document with encoding" begin
        # libxml2 test/title.xml
        xml = """<?xml version="1.0" encoding="utf-8"?>
<title>my title</title>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "title"
        @test simple_value(root) == "my title"
    end

    @testset "whitespace preservation in text content" begin
        xml = "<root>  hello  world  </root>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "  hello  world  "
    end

    @testset "tab and newline preservation" begin
        xml = "<root>\t\n\ttabbed\n</root>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "\t\n\ttabbed\n"
    end

    @testset "whitespace-only text node" begin
        xml = "<root>   </root>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "   "
    end

    @testset "inter-element whitespace preserved" begin
        xml = "<root>\n  <a/>\n  <b/>\n</root>"
        doc = parse(xml, Node)
        root = doc[1]
        text_nodes = filter(x -> nodetype(x) == Text, children(root))
        @test length(text_nodes) >= 1
    end
end

#==============================================================================#
#                    WELL-FORMED DOCUMENTS                                     #
#   From: test/boundaries1.xml, test/bigname.xml, test/bigname2.xml,          #
#         test/slashdot.xml, test/eve.xml, test/wap.xml, etc.                 #
#==============================================================================#
@testset "Well-Formed Documents" begin
    @testset "boundaries1: boundary conditions with entities and CDATA" begin
        # libxml2 test/boundaries1.xml (simplified - without DTD entity expansion)
        xml = """<?xml version="1.0"?>
<!DOCTYPE d [
    <!ENTITY a "]>">
    <!ENTITY b ']>'>
]>
<?pi p1?>
<d a=">" b='>'>
text
<![CDATA[cdata]]>
<?pi p2?>
</d>
<?pi p3?>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "d"
        @test root["a"] == ">"
        @test root["b"] == ">"
        cdata_nodes = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata_nodes) == 1
        @test value(cdata_nodes[1]) == "cdata"
    end

    @testset "bigname: very long element name" begin
        # libxml2 test/bigname.xml - element name with >10000 characters
        longname = "this_is_a_very_large_name_" * repeat("0123456789", 500) * "_end"
        xml = "<$(longname)/>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == longname
    end

    @testset "slashdot: real-world XML (ultramode feed)" begin
        # libxml2 test/slashdot.xml (simplified)
        xml = """<ultramode>
 <story>
    <title>100 Mbit/s on Fibre to the home</title>
    <url>http://slashdot.org/articles/99/06/06/1440211.shtml</url>
    <time>1999-06-06 14:39:59</time>
    <author>CmdrTaco</author>
    <department>wouldn't-it-be-nice</department>
    <topic>internet</topic>
    <comments>20</comments>
    <section>articles</section>
    <image>topicinternet.jpg</image>
  </story>
 <story>
    <title>Gimp 1.2 Preview</title>
    <url>http://slashdot.org/articles/99/06/06/1438246.shtml</url>
    <time>1999-06-06 14:38:40</time>
    <author>CmdrTaco</author>
    <department>stuff-to-read</department>
    <topic>gimp</topic>
    <comments>12</comments>
    <section>articles</section>
    <image>topicgimp.gif</image>
  </story>
</ultramode>"""
        doc = parse(xml, Node)
        root = doc[1]
        @test tag(root) == "ultramode"
        stories = filter(x -> nodetype(x) == Element && tag(x) == "story", children(root))
        @test length(stories) == 2
        title1 = first(filter(x -> nodetype(x) == Element && tag(x) == "title",
                              children(stories[1])))
        @test simple_value(title1) == "100 Mbit/s on Fibre to the home"
    end

    @testset "eve: document with external DTD reference and internal entity" begin
        # libxml2 test/eve.xml
        xml = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE spec PUBLIC "-//testspec//" "dtds/eve.dtd" [
<!ENTITY iso6.doc.date '29-May-1999'>
]>
<spec>
</spec>"""
        doc = parse(xml, Node)
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test contains(value(dtd), "PUBLIC")
        @test contains(value(dtd), "ENTITY")
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "spec"
    end

    @testset "deeply nested document" begin
        xml = "<a><b><c><d><e><f><g><h><i><j>deep</j></i></h></g></f></e></d></c></b></a>"
        doc = parse(xml, Node)
        @test simple_value(doc[1][1][1][1][1][1][1][1][1][1]) == "deep"
    end

    @testset "many sibling elements" begin
        items = join(["<item n=\"$i\">Item $i</item>" for i in 1:200])
        xml = "<root>$items</root>"
        doc = parse(xml, Node)
        elements = filter(x -> nodetype(x) == Element, children(doc[1]))
        @test length(elements) == 200
        @test elements[1]["n"] == "1"
        @test elements[200]["n"] == "200"
    end

    @testset "mixed content: text, elements, CDATA, comments, PIs" begin
        xml = """<doc>
  text before
  <child attr="v">child text</child>
  <!-- a comment -->
  <![CDATA[cdata content]]>
  <?pi data?>
  text after
</doc>"""
        doc = parse(xml, Node)
        root = doc[1]
        types = Set(nodetype(c) for c in children(root))
        @test Text in types
        @test Element in types
        @test Comment in types
        @test CData in types
        @test ProcessingInstruction in types
    end

    @testset "self-closing elements" begin
        xml = "<root><br/><hr /><img  /></root>"
        doc = parse(xml, Node)
        elements = filter(x -> nodetype(x) == Element, children(doc[1]))
        @test length(elements) == 3
        @test tag(elements[1]) == "br"
        @test tag(elements[2]) == "hr"
        @test tag(elements[3]) == "img"
        @test all(x -> length(children(x)) == 0, elements)
    end

    @testset "empty element: start-tag and end-tag" begin
        xml = "<root><empty></empty></root>"
        doc = parse(xml, Node)
        el = first(filter(x -> nodetype(x) == Element, children(doc[1])))
        @test tag(el) == "empty"
    end

    @testset "element names with hyphens, dots, underscores" begin
        xml = "<my-root><sub.element/><_private/></my-root>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == "my-root"
        elements = filter(x -> nodetype(x) == Element, children(doc[1]))
        @test tag(elements[1]) == "sub.element"
        @test tag(elements[2]) == "_private"
    end

    @testset "element names starting with underscore" begin
        xml = "<_root><__child/></_root>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == "_root"
    end

    @testset "numeric element names (with letter prefix)" begin
        xml = "<h1>heading</h1>"
        doc = parse(xml, Node)
        @test tag(doc[1]) == "h1"
        @test simple_value(doc[1]) == "heading"
    end
end

#==============================================================================#
#                    ROUNDTRIP: PARSE → WRITE → PARSE                          #
#   Tests that libxml2-style documents survive roundtrip processing            #
#==============================================================================#
@testset "Roundtrip" begin
    @testset "roundtrip: namespaced document" begin
        xml = """<?xml version="1.0"?>
<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/">
  <dia:diagramdata dia:testattr="test"/>
</dia:diagram>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        @test root["xmlns:dia"] == "http://www.lysator.liu.se/~alla/dia/"
    end

    @testset "roundtrip: DTD with internal subset" begin
        xml = """<!DOCTYPE doc [
<!ELEMENT doc (#PCDATA)>
]>
<doc>text</doc>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        dtd = first(filter(x -> nodetype(x) == DTD, children(doc2)))
        @test contains(value(dtd), "ELEMENT")
    end

    @testset "roundtrip: adjacent CDATA sections" begin
        xml = "<doc><![CDATA[abc]]><![CDATA[def]]></doc>"
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        cdata_nodes = filter(x -> nodetype(x) == CData, children(root))
        @test length(cdata_nodes) == 2
    end

    @testset "roundtrip: processing instructions" begin
        xml = """<?xml version="1.0"?>
<?document-start doc?>
<doc/>
<?document-end doc?>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        pis = filter(x -> nodetype(x) == ProcessingInstruction, children(doc2))
        @test length(pis) == 2
    end

    @testset "roundtrip: comments with special characters" begin
        xml = "<root><!-- special: <>&'\" --></root>"
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        comments = filter(x -> nodetype(x) == Comment, children(root))
        @test length(comments) == 1
    end

    @testset "roundtrip: entities in attributes" begin
        xml = """<doc a="a&amp;b" b="c&lt;d"/>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        @test root["a"] == "a&b"
        @test root["b"] == "c<d"
    end
end

#==============================================================================#
#                    ERROR CASES (must fail to parse)                           #
#   From: test/errors/*, test/namespaces/err_*.xml                             #
#==============================================================================#
@testset "Error Cases" begin
    @testset "errors/empty: empty document" begin
        # libxml2 test/errors/empty.xml
        # XML.jl is lenient: returns an empty Document for empty input
        doc = parse("", Node)
        @test nodetype(doc) == Document
        @test length(children(doc)) == 0
    end

    @testset "errors/extra-content: content after root element" begin
        # libxml2 test/errors/extra-content.xml
        # XML.jl is lenient: treats trailing text as a Text node in the Document
        doc = parse("<d/>x", Node)
        @test nodetype(doc) == Document
    end

    @testset "errors/invalid-start-tag-1: text-only document" begin
        # libxml2 test/errors/invalid-start-tag-1.xml
        # XML.jl is lenient: treats bare text as a Text node
        doc = parse("x", Node)
        @test nodetype(doc) == Document
    end

    @testset "errors/invalid-start-tag-2: lone <" begin
        # libxml2 test/errors/invalid-start-tag-2.xml
        @test_throws Exception parse("<", Node)
    end

    @testset "errors/doctype1: malformed DOCTYPE" begin
        # libxml2 test/errors/doctype1.xml - "<!DOCTYPE doc>[]>"
        # XML.jl is lenient: parses the DOCTYPE and treats []> as text
        doc = parse("<!DOCTYPE doc>[]>\n<doc/>", Node)
        @test nodetype(doc) == Document
    end

    @testset "errors/dup-xml-attr: duplicate xml: attribute" begin
        # libxml2 test/errors/dup-xml-attr.xml
        @test_throws Exception parse("""<doc xml:lang="en" xml:lang="de"/>""", Node)
    end

    @testset "errors/attr5: duplicate attribute" begin
        # libxml2 test/errors/attr5.xml
        @test_throws Exception parse("""<d xmlns="urn:foo">
    <a b="" b=""/>
</d>""", Node)
    end

    @testset "mismatched tags" begin
        @test_throws Exception parse("<a></b>", Node)
    end

    @testset "overlapping elements" begin
        @test_throws Exception parse("<a><b></a></b>", Node)
    end

    @testset "unclosed root element" begin
        @test_throws Exception parse("<root>", Node)
    end

    @testset "close tag without open" begin
        @test_throws Exception parse("</a>", Node)
    end

    @testset "unclosed comment" begin
        @test_throws Exception parse("<!-- no end", Node)
    end

    @testset "unclosed CDATA" begin
        @test_throws Exception parse("<![CDATA[no end", Node)
    end

    @testset "unclosed PI" begin
        @test_throws Exception parse("<?pi no end", Node)
    end

    @testset "unterminated attribute (double quote)" begin
        @test_throws Exception parse("""<a x="no end""", Node)
    end

    @testset "unterminated attribute (single quote)" begin
        @test_throws Exception parse("<a x='no end", Node)
    end

    @testset "duplicate attribute" begin
        @test_throws Exception parse("""<a x="1" x="2"/>""", Node)
    end

    @testset "attribute without value" begin
        @test_throws Exception parse("<a disabled/>", Node)
    end

    @testset "attribute with unquoted value" begin
        @test_throws Exception parse("<a x=hello/>", Node)
    end

    @testset "tag with space before name" begin
        @test_throws Exception parse("< root/>", Node)
    end

    @testset "lone < in text content" begin
        @test_throws Exception parse("<root>a < b</root>", Node)
    end

    @testset "close tag after self-closing" begin
        @test_throws Exception parse("<a/></a>", Node)
    end

    @testset "deeply mismatched nesting" begin
        @test_throws Exception parse("<a><b><c></b></c></a>", Node)
    end

    @testset "multiple unclosed tags" begin
        @test_throws Exception parse("<a><b><c>", Node)
    end
end

#==============================================================================#
#                    UNICODE SUPPORT                                            #
#   Tests borrowed from libxml2's UTF-8 handling tests                         #
#==============================================================================#
@testset "Unicode" begin
    @testset "Latin-1 characters" begin
        xml = "<doc>café résumé naïve</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "café résumé naïve"
    end

    @testset "CJK characters" begin
        xml = "<doc>中文日本語한국어</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "中文日本語한국어"
    end

    @testset "Cyrillic characters" begin
        xml = "<doc>Привет мир</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "Привет мир"
    end

    @testset "Arabic characters" begin
        xml = "<doc>مرحبا</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "مرحبا"
    end

    @testset "Emoji (4-byte UTF-8)" begin
        xml = "<doc>🍦🎉🚀</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "🍦🎉🚀"
    end

    @testset "Unicode in attribute values" begin
        xml = """<doc name="über" city="東京"/>"""
        doc = parse(xml, Node)
        @test doc[1]["name"] == "über"
        @test doc[1]["city"] == "東京"
    end

    @testset "Unicode in comments" begin
        xml = "<doc><!-- héllo wörld --></doc>"
        doc = parse(xml, Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc[1]))
        @test contains(value(comments[1]), "héllo")
    end

    @testset "Unicode in CDATA" begin
        xml = "<doc><![CDATA[日本語テスト]]></doc>"
        doc = parse(xml, Node)
        cdata = first(filter(x -> nodetype(x) == CData, children(doc[1])))
        @test value(cdata) == "日本語テスト"
    end

    @testset "Unicode in PI content" begin
        xml = "<doc><?mypi données à traiter?></doc>"
        doc = parse(xml, Node)
        pi = first(filter(x -> nodetype(x) == ProcessingInstruction, children(doc[1])))
        @test contains(value(pi), "données")
    end

    @testset "UTF-8 BOM handling" begin
        # libxml2 test/utf8bom.xml pattern
        xml = "\xef\xbb\xbf<?xml version=\"1.0\"?>\n<doc/>"
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "doc"
    end
end

#==============================================================================#
#                REAL-WORLD DOCUMENT PATTERNS                                  #
#   Patterns commonly tested by libxml2 (DAV, RDF, SOAP, SVG, etc.)           #
#==============================================================================#
@testset "Real-World Document Patterns" begin
    @testset "WebDAV-like document" begin
        # Inspired by libxml2 test/dav* series
        xml = """<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/container/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Example collection</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "D:multistatus"
        @test root["xmlns:D"] == "DAV:"
    end

    @testset "RDF-like document" begin
        # Inspired by libxml2 test/rdf1, test/rdf2
        xml = """<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
  <rdf:Description rdf:about="http://example.org/resource">
    <dc:title>Example Resource</dc:title>
    <dc:creator>John Doe</dc:creator>
  </rdf:Description>
</rdf:RDF>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "rdf:RDF"
        desc = first(filter(x -> nodetype(x) == Element, children(root)))
        @test desc["rdf:about"] == "http://example.org/resource"
    end

    @testset "SVG-like document" begin
        # Inspired by libxml2 test/svg1, test/svg2, test/svg3
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="200" height="200" viewBox="0 0 200 200">
  <defs>
    <linearGradient id="grad1" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:rgb(255,255,0);stop-opacity:1"/>
      <stop offset="100%" style="stop-color:rgb(255,0,0);stop-opacity:1"/>
    </linearGradient>
  </defs>
  <rect x="10" y="10" width="180" height="180" fill="url(#grad1)"/>
  <circle cx="100" cy="100" r="50" fill="blue" opacity="0.5"/>
  <text x="100" y="100" text-anchor="middle">Hello SVG</text>
</svg>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "svg"
        @test root["xmlns"] == "http://www.w3.org/2000/svg"
        @test root["width"] == "200"
    end

    @testset "SOAP-like envelope" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <soap:Body>
    <GetWeather xmlns="http://www.example.com/weather">
      <City>New York</City>
      <Country>US</Country>
    </GetWeather>
  </soap:Body>
</soap:Envelope>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "soap:Envelope"
    end

    @testset "Atom feed" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example Feed</title>
  <link href="http://example.org/"/>
  <updated>2003-12-13T18:30:02Z</updated>
  <author>
    <name>John Doe</name>
  </author>
  <id>urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6</id>
  <entry>
    <title>Atom-Powered Robots Run Amok</title>
    <link href="http://example.org/2003/12/13/atom03"/>
    <id>urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a</id>
    <updated>2003-12-13T18:30:02Z</updated>
    <summary>Some text.</summary>
  </entry>
</feed>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "feed"
        @test root["xmlns"] == "http://www.w3.org/2005/Atom"
    end

    @testset "plist-like document" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Name</key>
    <string>Example</string>
    <key>Version</key>
    <integer>42</integer>
    <key>Enabled</key>
    <true/>
    <key>Tags</key>
    <array>
      <string>alpha</string>
      <string>beta</string>
    </array>
  </dict>
</plist>"""
        doc = parse(xml, Node)
        plist = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(plist) == "plist"
        @test plist["version"] == "1.0"
    end

    @testset "XHTML with mixed content" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Test</title></head>
  <body>
    <p>This is <em>emphasized</em> and <strong>strong</strong> text.</p>
    <p>A link: <a href="http://example.com">click here</a>.</p>
    <hr/>
    <pre>  preformatted  text  </pre>
  </body>
</html>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "html"
        @test root["xmlns"] == "http://www.w3.org/1999/xhtml"
    end

    @testset "MathML-like document" begin
        xml = """<math xmlns="http://www.w3.org/1998/Math/MathML">
  <mrow>
    <msup><mi>x</mi><mn>2</mn></msup>
    <mo>+</mo>
    <msup><mi>y</mi><mn>2</mn></msup>
    <mo>=</mo>
    <msup><mi>z</mi><mn>2</mn></msup>
  </mrow>
</math>"""
        doc = parse(xml, Node)
        root = doc[1]
        @test tag(root) == "math"
        @test root["xmlns"] == "http://www.w3.org/1998/Math/MathML"
    end

    @testset "WML-like document (mobile)" begin
        # Inspired by libxml2 test/wml.xml
        xml = """<?xml version="1.0"?>
<!DOCTYPE wml PUBLIC "-//WAPFORUM//DTD WML 1.1//EN" "http://www.wapforum.org/DTD/wml_1.1.xml">
<wml>
  <card id="main" title="Main Menu">
    <p>Welcome to WML</p>
  </card>
</wml>"""
        doc = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test tag(root) == "wml"
    end
end

#==============================================================================#
#                    EDGE CASES                                                #
#   Additional edge cases inspired by libxml2 test patterns                    #
#==============================================================================#
@testset "Edge Cases" begin
    @testset "CDATA containing ]] not followed by >" begin
        xml = "<root><![CDATA[a]]b]]></root>"
        doc = parse(xml, Node)
        cdata = first(filter(x -> nodetype(x) == CData, children(doc[1])))
        @test value(cdata) == "a]]b"
    end

    @testset "comment containing --" begin
        # Note: -- inside comments is technically not well-formed per spec,
        # but many parsers tolerate single - characters
        xml = "<root><!-- one-dash and hyphen-ated --></root>"
        doc = parse(xml, Node)
        comments = filter(x -> nodetype(x) == Comment, children(doc[1]))
        @test length(comments) == 1
    end

    @testset "attribute value containing >" begin
        xml = """<doc attr="a>b"/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "a>b"
    end

    @testset "attribute value containing single quote in double quotes" begin
        xml = """<doc attr="it's"/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "it's"
    end

    @testset "attribute value containing double quote in single quotes" begin
        xml = "<doc attr='say \"hello\"'/>"
        doc = parse(xml, Node)
        @test doc[1]["attr"] == "say \"hello\""
    end

    @testset "very long attribute value" begin
        long_val = repeat("x", 10000)
        xml = """<doc attr="$(long_val)"/>"""
        doc = parse(xml, Node)
        @test doc[1]["attr"] == long_val
    end

    @testset "very long text content" begin
        long_text = repeat("word ", 5000)
        xml = "<doc>$(long_text)</doc>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == long_text
    end

    @testset "many attributes on one element" begin
        attrs = join(["a$i=\"v$i\"" for i in 1:50], " ")
        xml = "<doc $attrs/>"
        doc = parse(xml, Node)
        @test doc[1]["a1"] == "v1"
        @test doc[1]["a50"] == "v50"
    end

    @testset "whitespace around = in attributes" begin
        xml = """<doc a = "1" b  =  "2" />"""
        doc = parse(xml, Node)
        @test doc[1]["a"] == "1"
        @test doc[1]["b"] == "2"
    end

    @testset "tab and newline in tag whitespace" begin
        xml = "<doc\n\ta=\"1\"\n\tb=\"2\"\n/>"
        doc = parse(xml, Node)
        @test doc[1]["a"] == "1"
        @test doc[1]["b"] == "2"
    end

    @testset "empty element: self-closing vs open-close" begin
        xml1 = "<root><x/></root>"
        xml2 = "<root><x></x></root>"
        doc1 = parse(xml1, Node)
        doc2 = parse(xml2, Node)
        # Both should produce empty elements
        el1 = first(filter(x -> nodetype(x) == Element, children(doc1[1])))
        el2 = first(filter(x -> nodetype(x) == Element, children(doc2[1])))
        @test tag(el1) == tag(el2) == "x"
    end

    @testset "document with all prolog components" begin
        xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!DOCTYPE root [
  <!ELEMENT root (#PCDATA | child)*>
  <!ELEMENT child EMPTY>
  <!ATTLIST child id ID #REQUIRED>
  <!ENTITY greeting "Hello, World!">
]>
<!-- document comment -->
<?app-instruction data?>
<root>&greeting;<child id="c1"/></root>"""
        doc = parse(xml, Node)
        typed = filter(x -> nodetype(x) != Text, children(doc))
        type_list = map(nodetype, typed)
        @test Declaration in type_list
        @test DTD in type_list
        @test Comment in type_list
        @test ProcessingInstruction in type_list
        @test Element in type_list
    end
end

end  # top-level @testset
