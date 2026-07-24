using XML
using XML: Document, Element, Declaration, Comment, CData, DTD, ProcessingInstruction, Text
using XML: escape, unescape, h, parse_dtd
using XML: ParsedDTD, ElementDecl, AttDecl, EntityDecl, NotationDecl
using Test

# Run every testset below under one parent testset, so a failure or error in any single testset does
# not abort the rest of the file. We deliberately do NOT wrap the file body in a single
# `@testset begin … end` block: that compiles the whole ~3700-line body as one top-level thunk and is
# pathologically slow to compile. Instead each `@testset` stays its own top-level statement but nests
# under `_ROOT_TS` (a nested testset records into its parent rather than throwing at finish);
# `_ROOT_TS`'s finish() at the bottom prints the aggregated summary and throws once if anything failed.
const _ROOT_TS = Test.DefaultTestSet("XML.jl")
Test.push_testset(_ROOT_TS)

#==============================================================================#
#                              ESCAPE / UNESCAPE                               #
#==============================================================================#
@testset "escape / unescape" begin
    @testset "all five predefined entities" begin
        @test escape("&") == "&amp;"
        @test escape("<") == "&lt;"
        @test escape(">") == "&gt;"
        @test escape("'") == "&apos;"
        @test escape("\"") == "&quot;"
    end

    @testset "unescape reverses escape" begin
        @test unescape("&amp;") == "&"
        @test unescape("&lt;") == "<"
        @test unescape("&gt;") == ">"
        @test unescape("&apos;") == "'"
        @test unescape("&quot;") == "\""
    end

    @testset "roundtrip on mixed strings" begin
        s = "This > string < has & some \" special ' characters"
        @test unescape(escape(s)) == s
    end

    @testset "idempotent unescape" begin
        s = "plain text with no entities"
        @test unescape(s) == s
    end

    @testset "multiple entities in one string" begin
        @test escape("a < b & c > d") == "a &lt; b &amp; c &gt; d"
        @test unescape("a &lt; b &amp; c &gt; d") == "a < b & c > d"
    end

    @testset "empty string" begin
        @test escape("") == ""
        @test unescape("") == ""
    end

    @testset "#60: escape accepts SubString (AbstractString, not just String)" begin
        # MarkNahabedian #60: escape was specialized on String, so SubString threw. Guard the fix.
        s = SubString("x<y>z", 2, 4)   # "<y>"
        @test s isa SubString
        @test escape(s) == "&lt;y&gt;"
    end
end

#==============================================================================#
#              XML 1.0 SPEC SECTION 2.1: Well-Formed XML Documents             #
#==============================================================================#
@testset "Spec 2.1: Well-Formed XML Documents" begin
    # The spec's simplest example:
    #   <?xml version="1.0"?>
    #   <greeting>Hello, world!</greeting>
    xml = """<?xml version="1.0"?><greeting>Hello, world!</greeting>"""
    doc = parse(xml, Node)
    @test nodetype(doc) == Document
    @test length(doc) == 2  # Declaration + Element
    @test nodetype(doc[1]) == Declaration
    @test nodetype(doc[2]) == Element
    @test tag(doc[2]) == "greeting"
    @test simple_value(doc[2]) == "Hello, world!"

    # A well-formed document has exactly one root and no stray top-level markup.
    # v0.4 enforces this by default (`wellformed=:structural`); `:lenient` opts out.
    @testset "rejects ill-formed under :structural (the default)" begin
        @test_throws ErrorException parse("<a/><b/>", Node)       # multiple root elements
        @test_throws ErrorException parse("x<a/>", Node)          # non-whitespace text before root
        @test_throws ErrorException parse("<a/>x", Node)          # non-whitespace text after root
        @test_throws ErrorException parse("<></>", Node)          # empty element name
        @test_throws ErrorException parse("<1b>x</1b>", Node)     # name starts with a digit
        @test_throws ErrorException parse("<.d/>", Node)          # name starts with punctuation
    end

    @testset ":structural still accepts legal prolog/epilog" begin
        @test nodetype(parse("  <a/>  ", Node)) == Document       # whitespace around root is legal
        @test nodetype(parse("<!--c--><a/>", Node)) == Document   # comment before root
        @test nodetype(parse("""<?xml version="1.0"?><a/>""", Node)) == Document
    end

    @testset "rejects a document with markup but no root element (§2.1)" begin
        # §2.1: a well-formed document has exactly one root. Prolog-only markup (a comment,
        # XML/PI declaration, or DOCTYPE) with no root is not well-formed (libxml2: "no root").
        @test_throws ErrorException parse("<!-- comment -->", Node)
        @test_throws ErrorException parse("<!DOCTYPE x>", Node)
        @test_throws ErrorException parse("""<?xml version="1.0"?>""", Node)
        @test_throws ErrorException parse("<?pi go?>", Node)
        # empty ("") and whitespace-only input are both accepted, but differ: "" → an empty
        # Document; "   " → a Document whose only child is whitespace Text. :lenient opts out.
        @test nodetype(parse("", Node)) == Document
        @test isempty(children(parse("", Node)))
        @test nodetype(parse("   ", Node)) == Document
        @test nodetype(only(children(parse("   ", Node)))) == Text
        @test nodetype(parse("<!-- comment -->", Node; wellformed=:lenient)) == Document
    end

    @testset "rejects misplaced or duplicate DOCTYPE (§2.1 prolog)" begin
        # A DOCTYPE belongs in the prolog: a single declaration, before the root element.
        @test_throws ErrorException parse("<!DOCTYPE x><!DOCTYPE x><x/>", Node)   # duplicate
        @test_throws ErrorException parse("<x/><!DOCTYPE x>", Node)               # after the root
        @test_throws ErrorException parse("<r><!DOCTYPE x></r>", Node)            # nested in content
        # the well-formed case still parses, including at :strict
        @test nodetype(parse("<!DOCTYPE x><x/>", Node)) == Document
        @test nodetype(parse("<!DOCTYPE x><x/>", Node; wellformed=:strict)) == Document
        # :lenient opts out
        @test nodetype(parse("<x/><!DOCTYPE x>", Node; wellformed=:lenient)) == Document
    end

    @testset "rejects a misplaced or duplicate XML declaration (§2.8)" begin
        # The XML declaration must be the very first thing in the document.
        @test_throws ErrorException parse("""<r/><?xml version="1.0"?>""", Node)                       # after the root
        @test_throws ErrorException parse("""<?xml version="1.0"?><?xml version="1.0"?><r/>""", Node)  # duplicate
        @test_throws ErrorException parse("""<a><?xml version="1.0"?></a>""", Node)                    # nested in content
        @test_throws ErrorException parse("""<!--c--><?xml version="1.0"?><r/>""", Node)               # after a comment
        # the well-formed case still parses, including at :strict
        @test nodetype(parse("""<?xml version="1.0"?><r/>""", Node)) == Document
        @test nodetype(parse("""<?xml version="1.0"?><r/>""", Node; wellformed=:strict)) == Document
        # :lenient opts out
        @test nodetype(parse("""<r/><?xml version="1.0"?>""", Node; wellformed=:lenient)) == Document
    end

    @testset ":lenient opts out of well-formedness enforcement" begin
        @test nodetype(parse("<a/><b/>", Node; wellformed=:lenient)) == Document
        @test nodetype(parse("<></>", Node; wellformed=:lenient)) == Document
    end
end

#==============================================================================#
#         XML 1.0 SPEC SECTION 2.4: Character Data and Markup                  #
#==============================================================================#
@testset "Spec 2.4: Character Data and Markup" begin
    @testset "text content between tags" begin
        doc = parse("<root>Hello</root>", Node)
        @test simple_value(doc[1]) == "Hello"
    end

    @testset "entity references in text are unescaped" begin
        doc = parse("<root>&amp; &lt; &gt; &apos; &quot;</root>", Node)
        @test simple_value(doc[1]) == "& < > ' \""
    end

    @testset "mixed text and child elements" begin
        doc = parse("<p>Hello <b>world</b>!</p>", Node)
        root = doc[1]
        @test length(root) == 3
        @test nodetype(root[1]) == Text
        @test value(root[1]) == "Hello "
        @test nodetype(root[2]) == Element
        @test tag(root[2]) == "b"
        @test simple_value(root[2]) == "world"
        @test nodetype(root[3]) == Text
        @test value(root[3]) == "!"
    end

    @testset "empty element has no text" begin
        doc = parse("<empty/>", Node)
        @test length(children(doc[1])) == 0
    end

    @testset ":strict rejects characters outside the XML Char range (references and raw)" begin
        # XML §2.2 Char: #x0, surrogates, and code points > #x10FFFF are not legal characters.
        @test_throws Exception parse("<root>&#0;</root>", Node; wellformed=:strict)        # NUL
        @test_throws Exception parse("<root>&#xD800;</root>", Node; wellformed=:strict)    # surrogate
        @test_throws Exception parse("<root>&#xFFFFFF;</root>", Node; wellformed=:strict)  # > #x10FFFF
        @test_throws Exception parse("""<e a="&#0;"/>""", Node; wellformed=:strict)        # in an attribute too
        # legal refs still parse under :strict
        @test simple_value(parse("<root>&#x41;&#x9;</root>", Node; wellformed=:strict)[1]) == "A\t"

        # The RAW (literal) form of an illegal character is rejected too, not only the reference
        # form — in text, attributes, comments, CDATA, and PI content.
        @test_throws Exception parse("<root>a\x00b</root>", Node; wellformed=:strict)
        @test_throws Exception parse("<root x=\"a\x00b\"/>", Node; wellformed=:strict)
        @test_throws Exception parse("<root><!--a\x00b--></root>", Node; wellformed=:strict)
        @test_throws Exception parse("<root><![CDATA[a\x00b]]></root>", Node; wellformed=:strict)
        @test_throws Exception parse("<root><?t a\x00b?></root>", Node; wellformed=:strict)
        # legal content (incl. tab/newline) still parses at :strict
        @test nodetype(parse("<root>ok\ttext\n</root>", Node; wellformed=:strict)) == Document
        # :structural (default) and :lenient do not enforce the Char range (ref or raw)
        @test nodetype(parse("<root>&#0;</root>", Node)) == Document
        @test nodetype(parse("<root>a\x00b</root>", Node)) == Document
    end
end

#==============================================================================#
#                    XML 1.0 SPEC SECTION 2.5: Comments                        #
#==============================================================================#
@testset "Spec 2.5: Comments" begin
    @testset "basic comment (spec example)" begin
        # Spec example: <!-- declarations for <head> & <body> -->
        doc = parse("<root><!-- declarations for <head> &amp; <body> --></root>", Node)
        c = doc[1][1]
        @test nodetype(c) == Comment
        @test value(c) == " declarations for <head> &amp; <body> "
    end

    @testset "empty comment" begin
        doc = parse("<root><!----></root>", Node)
        c = doc[1][1]
        @test nodetype(c) == Comment
        @test value(c) == ""
    end

    @testset "comment before root element" begin
        doc = parse("<!-- before --><root/>", Node)
        @test nodetype(doc[1]) == Comment
        @test value(doc[1]) == " before "
        @test nodetype(doc[2]) == Element
    end

    @testset "comment after root element" begin
        doc = parse("<root/><!-- after -->", Node)
        @test nodetype(doc[1]) == Element
        @test nodetype(doc[2]) == Comment
    end

    @testset "comment with markup-like content preserved verbatim" begin
        doc = parse("<root><!-- <b>not</b> a tag --></root>", Node)
        @test value(doc[1][1]) == " <b>not</b> a tag "
    end

    @testset "multiple comments" begin
        doc = parse("<root><!-- A --><!-- B --></root>", Node)
        @test length(doc[1]) == 2
        @test value(doc[1][1]) == " A "
        @test value(doc[1][2]) == " B "
    end

    @testset ":strict rejects \"--\" or a trailing \"-\" in a comment (§2.5)" begin
        # XML §2.5: the string "--" must not occur within comments.
        @test_throws Exception parse("<root><!-- a -- b --></root>", Node; wellformed=:strict)
        # :structural (default) and :lenient accept it
        @test nodetype(parse("<root><!-- a -- b --></root>", Node)) == Document
        @test nodetype(parse("<root><!-- a -- b --></root>", Node; wellformed=:lenient)) == Document

        # §2.5 also forbids a "-" immediately before "-->" (the "--->" straddle that a
        # content-token-only "--" check misses).
        @test_throws Exception parse("<root><!-- foo ---></root>", Node; wellformed=:strict)
        @test nodetype(parse("<root><!-- foo ---></root>", Node)) == Document
        @test nodetype(parse("<root><!-- foo ---></root>", Node; wellformed=:lenient)) == Document
        # a "-" NOT abutting the close is well-formed even at :strict
        @test nodetype(parse("<root><!-- a - b --></root>", Node; wellformed=:strict)) == Document
    end
end

#==============================================================================#
#             XML 1.0 SPEC SECTION 2.6: Processing Instructions                #
#==============================================================================#
@testset "Spec 2.6: Processing Instructions" begin
    @testset "xml-stylesheet PI (spec example)" begin
        doc = parse("""<?xml-stylesheet type="text/xsl" href="style.xsl"?><root/>""", Node)
        pi = doc[1]
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "xml-stylesheet"
        @test contains(value(pi), "type=\"text/xsl\"")
    end

    @testset "PI with no content" begin
        doc = parse("<?target?><root/>", Node)
        pi = doc[1]
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "target"
        @test value(pi) === nothing
    end

    @testset "PI inside element" begin
        doc = parse("<root><?mypi some data?></root>", Node)
        pi = doc[1][1]
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "mypi"
        @test value(pi) == "some data"
    end

    @testset "PI content keeps trailing whitespace, drops leading separator (§2.6)" begin
        # §2.6: whitespace after the PITarget is the separator (not content), but trailing
        # whitespace before "?>" IS content — drop only the leading separator (lstrip, not strip).
        for R in (Node, LazyNode)
            @test value(parse("<r><?target hello   ?></r>", R)[1][1]) == "hello   "
        end
        c = XML.Cursor("<r><?target hello   ?></r>"); XML.next!(c); XML.next!(c)
        @test value(c) == "hello   "
        @test value(parse("<r><?t   x?></r>", Node)[1][1]) == "x"                      # leading sep removed
        @test XML.write(parse("<r><?target hello   ?></r>", Node)[1][1]) == "<?target hello   ?>"  # round-trips
        @test value(parse("<r><?target   ?></r>", Node)[1][1]) === nothing             # whitespace-only -> nothing
        @test value(parse("<r><?target?></r>", Node)[1][1]) === nothing                # empty -> nothing
    end

    @testset "PI after root element" begin
        doc = parse("<root/><?post-process?>", Node)
        @test nodetype(doc[2]) == ProcessingInstruction
        @test tag(doc[2]) == "post-process"
    end

    @testset ":strict rejects an empty or invalid PI target" begin
        # XML §2.6: a PI target must be a Name.
        @test_throws Exception parse("<root><? data?></root>", Node; wellformed=:strict)   # empty target
        @test_throws Exception parse("<root><?123?></root>", Node; wellformed=:strict)     # invalid name-start
        # a valid target (incl. "xml-stylesheet") still parses under :strict
        @test nodetype(parse("<?xml-stylesheet?><root/>", Node; wellformed=:strict)) == Document
        # :structural (default) and :lenient accept the empty target
        @test nodetype(parse("<root><? data?></root>", Node)) == Document
        @test nodetype(parse("<root><? data?></root>", Node; wellformed=:lenient)) == Document
    end
end

#==============================================================================#
#                XML 1.0 SPEC SECTION 2.7: CDATA Sections                      #
#==============================================================================#
@testset "Spec 2.7: CDATA Sections" begin
    @testset "CDATA preserves markup characters" begin
        # Spec example
        doc = parse("<root><![CDATA[<greeting>Hello, world!</greeting>]]></root>", Node)
        cd = doc[1][1]
        @test nodetype(cd) == CData
        @test value(cd) == "<greeting>Hello, world!</greeting>"
    end

    @testset "empty CDATA" begin
        doc = parse("<root><![CDATA[]]></root>", Node)
        cd = doc[1][1]
        @test nodetype(cd) == CData
        @test value(cd) == ""
    end

    @testset "CDATA with ampersands and less-thans" begin
        doc = parse("<root><![CDATA[a < b && c > d]]></root>", Node)
        @test value(doc[1][1]) == "a < b && c > d"
    end

    @testset "CDATA with special characters" begin
        doc = parse("<root><![CDATA[line1\nline2\ttab]]></root>", Node)
        @test value(doc[1][1]) == "line1\nline2\ttab"
    end

    @testset "CDATA mixed with text" begin
        doc = parse("<root>before<![CDATA[inside]]>after</root>", Node)
        @test length(doc[1]) == 3
        @test nodetype(doc[1][1]) == Text
        @test value(doc[1][1]) == "before"
        @test nodetype(doc[1][2]) == CData
        @test value(doc[1][2]) == "inside"
        @test nodetype(doc[1][3]) == Text
        @test value(doc[1][3]) == "after"
    end
end

#==============================================================================#
#        XML 1.0 SPEC SECTION 2.8: Prolog and Document Type Declaration        #
#==============================================================================#
@testset "Spec 2.8: Prolog and Document Type Declaration" begin
    @testset "XML declaration - version only" begin
        doc = parse("""<?xml version="1.0"?><root/>""", Node)
        decl = doc[1]
        @test nodetype(decl) == Declaration
        @test decl["version"] == "1.0"
    end

    @testset "XML declaration - version and encoding" begin
        doc = parse("""<?xml version="1.0" encoding="UTF-8"?><root/>""", Node)
        decl = doc[1]
        @test decl["version"] == "1.0"
        @test decl["encoding"] == "UTF-8"
    end

    @testset "XML declaration - all three pseudo-attributes" begin
        doc = parse("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?><root/>""", Node)
        decl = doc[1]
        @test decl["version"] == "1.0"
        @test decl["encoding"] == "UTF-8"
        @test decl["standalone"] == "yes"
    end

    @testset "XML declaration with single quotes" begin
        doc = parse("<?xml version='1.0'?><root/>", Node)
        @test doc[1]["version"] == "1.0"
    end

    @testset "no XML declaration" begin
        doc = parse("<root/>", Node)
        @test length(doc) == 1
        @test nodetype(doc[1]) == Element
    end

    @testset "DOCTYPE - SYSTEM" begin
        # Spec example
        doc = parse("""<!DOCTYPE greeting SYSTEM "hello.dtd"><greeting/>""", Node)
        dtd = doc[1]
        @test nodetype(dtd) == DTD
        @test contains(value(dtd), "greeting")
        @test contains(value(dtd), "SYSTEM")
        @test contains(value(dtd), "hello.dtd")
    end

    @testset "DOCTYPE - with internal subset" begin
        xml = """<!DOCTYPE greeting [
  <!ELEMENT greeting (#PCDATA)>
]><greeting>Hello, world!</greeting>"""
        doc = parse(xml, Node)
        dtd = doc[1]
        @test nodetype(dtd) == DTD
        @test contains(value(dtd), "greeting")
        @test contains(value(dtd), "<!ELEMENT")
    end

    @testset "DOCTYPE with entities (spec-like)" begin
        xml = """<!DOCTYPE note [
<!ENTITY nbsp "&#xA0;">
<!ENTITY writer "Writer: Donald Duck.">
<!ENTITY copyright "Copyright: W3Schools.">
]><note/>"""
        doc = parse(xml, Node)
        @test nodetype(doc[1]) == DTD
        @test contains(value(doc[1]), "ENTITY")
    end

    @testset "full prolog: declaration + DOCTYPE" begin
        xml = """<?xml version="1.0"?><!DOCTYPE root SYSTEM "root.dtd"><root/>"""
        doc = parse(xml, Node)
        @test nodetype(doc[1]) == Declaration
        @test nodetype(doc[2]) == DTD
        @test nodetype(doc[3]) == Element
    end
end

#==============================================================================#
#          XML 1.0 SPEC SECTION 2.9: Standalone Document Declaration           #
#==============================================================================#
@testset "Spec 2.9: Standalone Document Declaration" begin
    doc = parse("""<?xml version="1.0" standalone="yes"?><root/>""", Node)
    @test doc[1]["standalone"] == "yes"

    doc2 = parse("""<?xml version="1.0" standalone="no"?><root/>""", Node)
    @test doc2[1]["standalone"] == "no"
end

#==============================================================================#
#              XML 1.0 SPEC SECTION 2.10: White Space Handling                 #
#==============================================================================#
@testset "Spec 2.10: White Space Handling" begin
    @testset "parser preserves all text content verbatim" begin
        doc = parse("<root>  hello  </root>", Node)
        @test simple_value(doc[1]) == "  hello  "
    end

    @testset "parser preserves whitespace-only text" begin
        doc = parse("<root>   </root>", Node)
        @test simple_value(doc[1]) == "   "
    end

    @testset "parser preserves inter-element whitespace as Text nodes" begin
        xml = "<root><a>x</a>\n  <b>y</b></root>"
        doc = parse(xml, Node)
        @test length(doc[1]) == 3
        @test value(doc[1][1][1]) == "x"
        @test nodetype(doc[1][2]) == Text
        @test value(doc[1][2]) == "\n  "
        @test value(doc[1][3][1]) == "y"
    end

    @testset "eachelement/elements skip non-element children" begin
        xml = "<root>\n  <a>x</a>\n  <!-- note -->\n  <b>y</b>\n</root>"
        for T in (Node, LazyNode)
            doc = parse(xml, T)
            root = only(elements(doc))
            @test tag(root) == "root"
            @test length(children(root)) == 7  # 4 Text runs + Comment + 2 Elements
            @test [tag(el) for el in eachelement(root)] == ["a", "b"]
            @test elements(root) == collect(eachelement(root))
            @test all(n -> nodetype(n) === XML.Element, elements(root))
            a = first(eachelement(root))
            @test isempty(elements(children(a)[1]))  # Text leaf has no elements
        end
    end

    @testset "xml:space attribute is preserved during parsing" begin
        doc = parse("""<root xml:space="preserve"><child>  text  </child></root>""", Node)
        @test doc[1]["xml:space"] == "preserve"
        @test value(doc[1][1][1]) == "  text  "
    end

    @testset "xml:space='preserve' affects write formatting" begin
        # When xml:space="preserve", writer doesn't add indentation
        el = Element("s", XML.Text(" pre "), Element("t"), XML.Text(" post "); var"xml:space"="preserve")
        @test XML.write(el) == "<s xml:space=\"preserve\"> pre <t/> post </s>"
    end

    @testset "write formats with indentation by default" begin
        el = Element("root", Element("a"), Element("b"))
        s = XML.write(el)
        @test contains(s, "  <a/>")  # indented
        @test contains(s, "  <b/>")  # indented
    end

    @testset "Unicode non-breaking space is NOT XML whitespace" begin
        nbsp = "\u00A0"
        xml = "<root>$(nbsp) y $(nbsp)</root>"
        doc = parse(xml, Node)
        @test simple_value(doc[1]) == "$(nbsp) y $(nbsp)"
    end
end

#==============================================================================#
#       XML 1.0 SPEC SECTION 3.1: Start-Tags, End-Tags, Empty-Element Tags     #
#==============================================================================#
@testset "Spec 3.1: Start-Tags, End-Tags, Empty-Element Tags" begin
    @testset "element with attributes (spec example)" begin
        # <termdef id="dt-dog" term="dog">
        doc = parse("""<termdef id="dt-dog" term="dog">A dog.</termdef>""", Node)
        el = doc[1]
        @test tag(el) == "termdef"
        @test el["id"] == "dt-dog"
        @test el["term"] == "dog"
        @test value(el[1]) == "A dog."
    end

    @testset "self-closing tag (spec example)" begin
        # <IMG align="left" src="http://www.w3.org/Icons/WWW/w3c_home"/>
        doc = parse("""<IMG align="left" src="http://www.w3.org/Icons/WWW/w3c_home"/>""", Node)
        el = doc[1]
        @test tag(el) == "IMG"
        @test el["align"] == "left"
        @test el["src"] == "http://www.w3.org/Icons/WWW/w3c_home"
        @test length(children(el)) == 0
    end

    @testset "simple self-closing tag" begin
        doc = parse("<br/>", Node)
        @test tag(doc[1]) == "br"
        @test length(children(doc[1])) == 0
    end

    @testset "self-closing tag with space before />" begin
        doc = parse("<br />", Node)
        @test tag(doc[1]) == "br"
    end

    @testset "empty element with start and end tag" begin
        doc = parse("<empty></empty>", Node)
        el = doc[1]
        @test tag(el) == "empty"
        @test isnothing(el.children)
    end

    @testset "nested elements" begin
        doc = parse("<a><b><c/></b></a>", Node)
        @test tag(doc[1]) == "a"
        @test tag(doc[1][1]) == "b"
        @test tag(doc[1][1][1]) == "c"
    end

    @testset "sibling elements" begin
        doc = parse("<root><a/><b/><c/></root>", Node)
        @test length(doc[1]) == 3
        @test tag(doc[1][1]) == "a"
        @test tag(doc[1][2]) == "b"
        @test tag(doc[1][3]) == "c"
    end

    @testset "attributes with single quotes" begin
        doc = parse("<x a='val'/>", Node)
        @test doc[1]["a"] == "val"
    end

    @testset "attributes with double quotes" begin
        doc = parse("""<x a="val"/>""", Node)
        @test doc[1]["a"] == "val"
    end

    @testset "mixed quote styles in attributes" begin
        doc = parse("""<x a="1" b='2'/>""", Node)
        @test doc[1]["a"] == "1"
        @test doc[1]["b"] == "2"
    end

    @testset "attribute with > in value" begin
        doc = parse("""<x a="1>2"/>""", Node)
        @test doc[1]["a"] == "1>2"
    end

    @testset "literal < in attribute value rejected (§3.1)" begin
        # §3.1 AttValue ::= '"' ([^<&"] | Reference)* '"' — a raw '<' is not well-formed
        # (whereas '>' above is), and &lt; is the correct way to include '<'.
        @test_throws Exception parse("""<x a="1<2"/>""", Node)                      # :structural default
        @test_throws Exception parse("""<x a="1<2"/>""", Node; wellformed=:strict)
        @test parse("""<x a="1<2"/>""", Node; wellformed=:lenient)[1]["a"] == "1<2" # :lenient accepts
        @test parse("""<x a="1&lt;2"/>""", Node)[1]["a"] == "1<2"                    # &lt; is well-formed
    end

    @testset "attribute with entity reference" begin
        doc = parse("""<x a="a&amp;b"/>""", Node)
        @test doc[1]["a"] == "a&b"
    end

    @testset "multiple attributes accessible via attributes()" begin
        doc = parse("""<x first="1" second="2" third="3"/>""", Node)
        attrs = attributes(doc[1])
        @test attrs isa Attributes
        @test attrs["first"] == "1"
        @test attrs["second"] == "2"
        @test attrs["third"] == "3"
    end

    @testset "whitespace around = in attributes" begin
        doc = parse("""<x a = "1" />""", Node)
        @test doc[1]["a"] == "1"
    end
end

#==============================================================================#
#                  XML 1.0 SPEC SECTION 4.1: Entity References                 #
#==============================================================================#
@testset "Spec 4.1: Character and Entity References" begin
    @testset "predefined entity references in text" begin
        doc = parse("<root>&lt;</root>", Node)
        @test simple_value(doc[1]) == "<"

        doc = parse("<root>&gt;</root>", Node)
        @test simple_value(doc[1]) == ">"

        doc = parse("<root>&amp;</root>", Node)
        @test simple_value(doc[1]) == "&"

        doc = parse("<root>&apos;</root>", Node)
        @test simple_value(doc[1]) == "'"

        doc = parse("<root>&quot;</root>", Node)
        @test simple_value(doc[1]) == "\""
    end

    @testset "predefined entities in attribute values" begin
        doc = parse("""<x a="&lt;&gt;&amp;&apos;&quot;"/>""", Node)
        @test doc[1]["a"] == "<>&'\""
    end

    @testset "multiple entity references in one text node" begin
        doc = parse("<root>&lt;tag&gt; &amp; &quot;value&quot;</root>", Node)
        @test simple_value(doc[1]) == "<tag> & \"value\""
    end
end

#==============================================================================#
#                  NAMESPACES (Colon in Tag and Attribute Names)                #
#==============================================================================#
@testset "Namespaces" begin
    @testset "namespaced element" begin
        doc = parse("""<ns:root xmlns:ns="http://example.com"><ns:child/></ns:root>""", Node)
        @test tag(doc[1]) == "ns:root"
        @test doc[1]["xmlns:ns"] == "http://example.com"
        @test tag(doc[1][1]) == "ns:child"
    end

    @testset "default namespace" begin
        doc = parse("""<root xmlns="http://example.com"/>""", Node)
        @test doc[1]["xmlns"] == "http://example.com"
    end

    @testset "multiple namespace prefixes" begin
        xml = """<root xmlns:a="http://a.com" xmlns:b="http://b.com"><a:x/><b:y/></root>"""
        doc = parse(xml, Node)
        @test tag(doc[1][1]) == "a:x"
        @test tag(doc[1][2]) == "b:y"
    end
end

#==============================================================================#
#                           NODE CONSTRUCTORS                                  #
#==============================================================================#
@testset "Node Constructors" begin
    @testset "Text" begin
        t = Text("hello")
        @test nodetype(t) == Text
        @test value(t) == "hello"
        @test tag(t) === nothing
        @test attributes(t) === nothing
    end

    @testset "Comment" begin
        c = Comment(" a comment ")
        @test nodetype(c) == Comment
        @test value(c) == " a comment "
    end

    @testset "CData" begin
        cd = CData("raw <data>")
        @test nodetype(cd) == CData
        @test value(cd) == "raw <data>"
    end

    @testset "DTD" begin
        d = DTD("html")
        @test nodetype(d) == DTD
        @test value(d) == "html"
    end

    @testset "Declaration" begin
        decl = Declaration(; version="1.0", encoding="UTF-8")
        @test nodetype(decl) == Declaration
        @test decl["version"] == "1.0"
        @test decl["encoding"] == "UTF-8"
    end

    @testset "Declaration with no attributes" begin
        decl = Declaration()
        @test nodetype(decl) == Declaration
        @test attributes(decl) === nothing
    end

    @testset "ProcessingInstruction with content" begin
        pi = ProcessingInstruction("target", "data here")
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "target"
        @test value(pi) == "data here"
    end

    @testset "ProcessingInstruction without content" begin
        pi = ProcessingInstruction("target")
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "target"
        @test value(pi) === nothing
    end

    @testset "Element with tag only" begin
        el = Element("div")
        @test nodetype(el) == Element
        @test tag(el) == "div"
        @test length(children(el)) == 0
    end

    @testset "Element with children" begin
        el = Element("div", Text("hello"), Element("span"))
        @test length(el) == 2
        @test nodetype(el[1]) == Text
        @test nodetype(el[2]) == Element
    end

    @testset "Element with attributes" begin
        el = Element("div"; class="main", id="content")
        @test el["class"] == "main"
        @test el["id"] == "content"
    end

    @testset "Element with children and attributes" begin
        el = Element("a", "click here"; href="http://example.com")
        @test tag(el) == "a"
        @test el["href"] == "http://example.com"
        @test value(el[1]) == "click here"
    end

    @testset "Element auto-converts non-Node children to Text" begin
        el = Element("p", 42)
        @test nodetype(el[1]) == Text
        @test value(el[1]) == "42"
    end

    @testset "Document" begin
        doc = Document(
            Declaration(; version="1.0"),
            Element("root")
        )
        @test nodetype(doc) == Document
        @test length(doc) == 2
        @test nodetype(doc[1]) == Declaration
        @test nodetype(doc[2]) == Element
    end

    @testset "Document with all node types" begin
        doc = Document(
            Declaration(; version="1.0"),
            DTD("root"),
            Comment("comment"),
            ProcessingInstruction("pi", "data"),
            Element("root", CData("cdata"), Text("text"))
        )
        @test map(nodetype, children(doc)) == [Declaration, DTD, Comment, ProcessingInstruction, Element]
        @test length(doc[end]) == 2
        @test nodetype(doc[end][1]) == CData
        @test value(doc[end][1]) == "cdata"
        @test nodetype(doc[end][2]) == Text
        @test value(doc[end][2]) == "text"
    end

    @testset "invalid constructions" begin
        @test_throws Exception Text("a", "b")               # too many args
        @test_throws Exception Comment("a"; x="1")           # no attrs
        @test_throws Exception CData("a"; x="1")             # no attrs
        @test_throws Exception DTD("a"; x="1")               # no attrs
        @test_throws Exception Element()                      # need tag
        @test_throws Exception Declaration("bad")             # no positional args
        @test_throws Exception Document(; x="1")              # no attrs
        @test_throws Exception ProcessingInstruction()        # need target
        @test_throws Exception ProcessingInstruction("a", "b", "c")  # too many args

        # invalid XML names are rejected, so a constructed node can't serialize to malformed XML (§2.3)
        @test_throws Exception Element("")         # empty name -> "</>"
        @test_throws Exception Element("1bad")     # name starts with a digit
        @test_throws Exception Element(".d")        # name starts with punctuation
        @test_throws Exception Element("a b")       # whitespace in name -> "<a b/>"
        @test_throws Exception Element("a<b")       # markup char in name
        @test_throws Exception ProcessingInstruction("1bad", "x")   # invalid PI target
        # valid names (incl. namespaced and non-ASCII) still construct
        @test tag(Element("ok")) == "ok"
        @test tag(Element("ns:item")) == "ns:item"
        @test tag(Element("café")) == "café"
        @test tag(ProcessingInstruction("php", "echo")) == "php"

        # content containing its own close delimiter is un-representable (write would split it)
        @test_throws Exception Comment("a-->b")
        @test_throws Exception CData("a]]>b")
        @test_throws Exception ProcessingInstruction("t", "a?>b")
        # the delimiter's characters individually (not the full close sequence) are fine
        @test value(Comment("a-b->c")) == "a-b->c"
        @test value(CData("a]b]>c")) == "a]b]>c"
        @test value(ProcessingInstruction("t", "a? >b")) == "a? >b"
    end
end

#==============================================================================#
#                        h CONSTRUCTOR                                         #
#==============================================================================#
@testset "h constructor" begin
    @testset "h(tag)" begin
        el = h("div")
        @test nodetype(el) == Element
        @test tag(el) == "div"
    end

    @testset "h(tag, children...)" begin
        el = h("div", "hello")
        @test simple_value(el) == "hello"
    end

    @testset "h(tag; attrs...)" begin
        el = h("div"; class="main")
        @test el["class"] == "main"
    end

    @testset "h(tag, children...; attrs...)" begin
        el = h("div", "hello"; class="main")
        @test el["class"] == "main"
        @test value(el[1]) == "hello"
    end

    @testset "h.tag syntax" begin
        el = h.div("hello"; class="main")
        @test tag(el) == "div"
        @test el["class"] == "main"
        @test value(el[1]) == "hello"
    end

    @testset "h.tag with no args" begin
        el = h.br()
        @test tag(el) == "br"
        @test length(children(el)) == 0
    end

    @testset "h.tag with only attrs" begin
        el = h.img(; src="image.png")
        @test tag(el) == "img"
        @test el["src"] == "image.png"
    end

    @testset "nested h constructors" begin
        el = h.div(
            h.h1("Title"),
            h.p("Paragraph")
        )
        @test tag(el) == "div"
        @test length(el) == 2
        @test tag(el[1]) == "h1"
        @test tag(el[2]) == "p"
    end

    @testset "h with symbol tag" begin
        el = h(:div)
        @test tag(el) == "div"
    end
end

#==============================================================================#
#                        NODE INTERFACE                                        #
#==============================================================================#
@testset "Node Interface" begin
    doc = parse("""<?xml version="1.0"?><root attr="val"><child>text</child></root>""", Node)

    @testset "nodetype" begin
        @test nodetype(doc) == Document
        @test nodetype(doc[1]) == Declaration
        @test nodetype(doc[2]) == Element
    end

    @testset "tag" begin
        @test tag(doc) === nothing
        @test tag(doc[2]) == "root"
        @test tag(doc[2][1]) == "child"
    end

    @testset "attributes" begin
        @test attributes(doc) === nothing
        @test attributes(doc[2])["attr"] == "val"
    end

    @testset "value" begin
        @test value(doc) === nothing
        @test value(doc[2][1][1]) == "text"
    end

    @testset "children" begin
        @test length(children(doc)) == 2
        @test length(children(doc[2])) == 1
    end

    @testset "is_simple" begin
        @test is_simple(doc[2][1]) == true
        @test is_simple(doc[2]) == false
    end

    @testset "simple_value" begin
        @test simple_value(doc[2][1]) == "text"
        @test_throws ErrorException simple_value(doc[2])
    end

    @testset "simple_value for CData child" begin
        el = Element("x", CData("data"))
        @test is_simple(el)
        @test simple_value(el) == "data"
    end
end

#==============================================================================#
#                        NODE INDEXING                                          #
#==============================================================================#
@testset "Node Indexing" begin
    doc = parse("<root><a/><b/><c/></root>", Node)
    root = doc[1]

    @testset "integer indexing" begin
        @test tag(root[1]) == "a"
        @test tag(root[2]) == "b"
        @test tag(root[3]) == "c"
    end

    @testset "colon indexing" begin
        all = root[:]
        @test length(all) == 3
    end

    @testset "lastindex" begin
        @test tag(root[end]) == "c"
    end

    @testset "only" begin
        single = parse("<root><only/></root>", Node)
        @test tag(only(single[1])) == "only"
    end

    @testset "length" begin
        @test length(root) == 3
    end

    @testset "attribute indexing" begin
        el = parse("""<x a="1" b="2"/>""", Node)[1]
        @test el["a"] == "1"
        @test el["b"] == "2"
        @test_throws KeyError el["nonexistent"]
    end

    @testset "haskey" begin
        el = parse("""<x a="1"/>""", Node)[1]
        @test haskey(el, "a") == true
        @test haskey(el, "b") == false
    end

    @testset "keys" begin
        el = parse("""<x a="1" b="2"/>""", Node)[1]
        @test collect(keys(el)) == ["a", "b"]
    end

    @testset "keys on element with no attributes" begin
        el = parse("<x/>", Node)[1]
        @test isempty(keys(el))
    end
end

#==============================================================================#
#                        NODE MUTATION                                         #
#==============================================================================#
@testset "Node Mutation" begin
    @testset "setindex! child" begin
        el = Element("root", Element("old"))
        el[1] = Element("new")
        @test tag(el[1]) == "new"
    end

    @testset "setindex! child with auto-conversion" begin
        el = Element("root", Text("old"))
        el[1] = "new text"
        @test value(el[1]) == "new text"
    end

    @testset "setindex! attribute" begin
        el = Element("root"; a="1")
        el["a"] = "2"
        @test el["a"] == "2"
    end

    @testset "setindex! new attribute" begin
        el = Element("root"; a="1")
        el["b"] = "2"
        @test el["b"] == "2"
    end

    @testset "push! child" begin
        el = Element("root")
        push!(el, Element("child"))
        @test length(el) == 1
        @test tag(el[1]) == "child"
    end

    @testset "push! with auto-conversion" begin
        el = Element("root")
        push!(el, "text")
        @test nodetype(el[1]) == Text
        @test value(el[1]) == "text"
    end

    @testset "pushfirst! child" begin
        el = Element("root", Element("second"))
        pushfirst!(el, Element("first"))
        @test tag(el[1]) == "first"
        @test tag(el[2]) == "second"
    end

    @testset "push! on non-container node errors" begin
        t = Text("hello")
        @test_throws ErrorException push!(t, "more")
    end
end

#==============================================================================#
#                        NODE EQUALITY                                         #
#==============================================================================#
@testset "Node Equality" begin
    @testset "identical elements are equal" begin
        a = Element("div", Text("hello"); class="main")
        b = Element("div", Text("hello"); class="main")
        @test a == b
    end

    @testset "different tag names are not equal" begin
        @test Element("a") != Element("b")
    end

    @testset "different attributes are not equal" begin
        @test Element("a"; x="1") != Element("a"; x="2")
    end

    @testset "different children are not equal" begin
        @test Element("a", Text("x")) != Element("a", Text("y"))
    end

    @testset "different node types are not equal" begin
        @test Text("x") != Comment("x")
    end

    @testset "empty attributes vs nothing" begin
        a = Element("a")
        b = Element("a")
        @test a == b
    end

    @testset "parse equality" begin
        xml = "<root><child>text</child></root>"
        @test parse(xml, Node) == parse(xml, Node)
    end
end

#==============================================================================#
#                        XML WRITING                                           #
#==============================================================================#
@testset "XML Writing" begin
    @testset "write Text" begin
        el = Element("p", "hello & goodbye")
        @test XML.write(el) == "<p>hello &amp; goodbye</p>"
    end

    @testset "write Element with attributes" begin
        el = Element("div"; class="main", id="content")
        s = XML.write(el)
        @test contains(s, "<div")
        @test contains(s, "class=\"main\"")
        @test contains(s, "id=\"content\"")
        @test contains(s, "/>")
    end

    @testset "write self-closing element" begin
        @test XML.write(Element("br")) == "<br/>"
    end

    @testset "write element with single text child (inline)" begin
        @test XML.write(Element("p", "hello")) == "<p>hello</p>"
    end

    @testset "write element with multiple children (indented)" begin
        el = Element("div", Element("a"), Element("b"))
        s = XML.write(el)
        @test contains(s, "<div>")
        @test contains(s, "  <a/>")
        @test contains(s, "  <b/>")
        @test contains(s, "</div>")
    end

    @testset "write Comment" begin
        el = Element("root", Comment(" comment "))
        @test contains(XML.write(el), "<!-- comment -->")
    end

    @testset "write CData" begin
        el = Element("root", CData("raw <data>"))
        @test contains(XML.write(el), "<![CDATA[raw <data>]]>")
    end

    @testset "write ProcessingInstruction with content" begin
        pi = ProcessingInstruction("target", "data")
        @test XML.write(pi) == "<?target data?>"
    end

    @testset "write ProcessingInstruction without content" begin
        pi = ProcessingInstruction("target")
        @test XML.write(pi) == "<?target?>"
    end

    @testset "write Declaration" begin
        decl = Declaration(; version="1.0", encoding="UTF-8")
        s = XML.write(decl)
        @test contains(s, "<?xml")
        @test contains(s, "version=\"1.0\"")
        @test contains(s, "encoding=\"UTF-8\"")
        @test contains(s, "?>")
    end

    @testset "write DTD" begin
        dtd = DTD("html")
        @test XML.write(dtd) == "<!DOCTYPE html>"
    end

    @testset "write Document" begin
        doc = Document(Declaration(; version="1.0"), Element("root"))
        s = XML.write(doc)
        @test startswith(s, "<?xml")
        @test contains(s, "<root/>")
    end

    @testset "write escapes special characters in text" begin
        el = Element("p", "a < b & c > d")
        @test XML.write(el) == "<p>a &lt; b &amp; c &gt; d</p>"
    end

    @testset "write escapes special characters in attribute values" begin
        el = Element("x"; a="a\"b")
        @test contains(XML.write(el), "a=\"a&quot;b\"")
    end

    @testset "indentsize parameter" begin
        el = Element("root", Element("child"))
        s2 = XML.write(el; indentsize=2)
        s4 = XML.write(el; indentsize=4)
        @test contains(s2, "  <child/>")
        @test contains(s4, "    <child/>")
    end

    @testset "write xml:space='preserve' respects whitespace" begin
        el = Element("root", Element("p", Text("  hello  "); var"xml:space"="preserve"))
        s = XML.write(el)
        @test contains(s, ">  hello  </p>")
    end
end

#==============================================================================#
#                 WRITE TO FILE / READ FROM FILE                               #
#==============================================================================#
@testset "File I/O" begin
    @testset "write and read back" begin
        doc = Document(
            Declaration(; version="1.0"),
            Element("root", Element("child", "text"))
        )
        temp = tempname() * ".xml"
        XML.write(temp, doc)
        content = read(temp, String)
        @test contains(content, "<?xml")
        @test contains(content, "<root>")
        @test contains(content, "<child>text</child>")
        doc2 = read(temp, Node)
        @test nodetype(doc2) == Document
        # Find the root element
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        child = first(filter(x -> nodetype(x) == Element, children(root)))
        @test tag(child) == "child"
        @test simple_value(child) == "text"
        rm(temp)
    end

    @testset "read from IO" begin
        xml = """<?xml version="1.0"?><root>hello</root>"""
        doc = read(IOBuffer(xml), Node)
        @test nodetype(doc) == Document
        root = first(filter(x -> nodetype(x) == Element, children(doc)))
        @test simple_value(root) == "hello"
    end

    @testset "byte-order mark handling (§4.3.3)" begin
        # BOM-prefixed input must decode to UTF-8 before parsing (guards the _normalize_bom port).
        @test tag(read(IOBuffer(UInt8[0xFF,0xFE, 0x3C,0x00,0x61,0x00,0x2F,0x00,0x3E,0x00]), Node)[1]) == "a"  # UTF-16 LE BOM + <a/>
        @test tag(read(IOBuffer(UInt8[0xFE,0xFF, 0x00,0x3C,0x00,0x61,0x00,0x2F,0x00,0x3E]), Node)[1]) == "a"  # UTF-16 BE BOM + <a/>
        @test tag(read(IOBuffer(UInt8[0xEF,0xBB,0xBF, 0x3C,0x61,0x2F,0x3E]), Node)[1]) == "a"                  # UTF-8 BOM + <a/>
        # §4.3.3: UTF-16 entities MUST start with a BOM; a leading NUL byte is the signature →
        # raise a clear error rather than crash the UTF-8 parser downstream.
        @test_throws "UTF-16 without a BOM" read(IOBuffer(UInt8[0x00,0x3C,0x00,0x61,0x00,0x2F,0x00,0x3E]), Node)  # UTF-16 BE, no BOM
        @test_throws "UTF-16 without a BOM" read(IOBuffer(UInt8[0x3C,0x00,0x61,0x00,0x2F,0x00,0x3E,0x00]), Node)  # UTF-16 LE, no BOM
        # An odd byte count after a UTF-16 BOM is truncated — raise a clear error, not a cryptic
        # `reinterpret` ArgumentError.
        @test_throws "odd number of bytes" read(IOBuffer(UInt8[0xFF,0xFE, 0x3C,0x00, 0x61]), Node)  # LE BOM + 3 bytes
        @test_throws "odd number of bytes" read(IOBuffer(UInt8[0xFE,0xFF, 0x00,0x3C, 0x00]), Node)  # BE BOM + 3 bytes

        # A leading U+FEFF as a *character* in an in-memory string is an encoding signature,
        # not content — every reader must drop it, not surface it as a leading Text node, so
        # Node / LazyNode / Cursor agree on the same string.
        let bom = "﻿<r>x</r>"
            @test nodetype(parse(bom, Node)[1])     == Element
            @test tag(parse(bom, Node)[1])          == "r"
            @test nodetype(parse(bom, LazyNode)[1]) == Element
            @test tag(parse(bom, LazyNode)[1])      == "r"
            c = XML.Cursor(bom); XML.next!(c)
            @test nodetype(c) == Element
            @test tag(c)      == "r"
            # a string without a BOM is unaffected
            @test tag(parse("<r>x</r>", LazyNode)[1]) == "r"
        end
    end
end

#==============================================================================#
#                        PARSE → WRITE → PARSE ROUNDTRIP                       #
#==============================================================================#
@testset "Roundtrip: parse → write preserves semantics" begin
    @testset "declaration and root" begin
        xml = """<?xml version="1.0"?><root/>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        decls = filter(x -> nodetype(x) == Declaration, children(doc2))
        @test length(decls) == 1
        @test decls[1]["version"] == "1.0"
        els = filter(x -> nodetype(x) == Element, children(doc2))
        @test length(els) == 1
        @test tag(els[1]) == "root"
    end

    @testset "element with attributes and text" begin
        xml = """<root><child attr="val">text</child></root>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        child = first(filter(x -> nodetype(x) == Element, children(root)))
        @test tag(child) == "child"
        @test child["attr"] == "val"
        text_children = filter(x -> nodetype(x) == Text, children(child))
        @test any(t -> value(t) == "text", text_children)
    end

    @testset "all special node types survive roundtrip" begin
        xml = """<root><!-- comment --><![CDATA[data]]><?pi content?></root>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        types = map(nodetype, filter(x -> nodetype(x) != Text, children(root)))
        @test Comment in types
        @test CData in types
        @test ProcessingInstruction in types
    end

    @testset "DOCTYPE survives roundtrip" begin
        xml = """<!DOCTYPE html><html><body/></html>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        dtds = filter(x -> nodetype(x) == DTD, children(doc2))
        @test length(dtds) == 1
        @test value(dtds[1]) == "html"
    end

    @testset "namespace attributes survive roundtrip" begin
        xml = """<root xmlns:ns="http://example.com"><ns:child/></root>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        @test root["xmlns:ns"] == "http://example.com"
        child = first(filter(x -> nodetype(x) == Element, children(root)))
        @test tag(child) == "ns:child"
    end

    @testset "mixed content survives roundtrip" begin
        xml = """<p>Hello <b>world</b>!</p>"""
        doc = parse(xml, Node)
        s = XML.write(doc)
        doc2 = parse(s, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        non_ws = filter(x -> !(nodetype(x) == Text && isempty(strip(value(x)))), children(root))
        texts = [value(x) for x in non_ws if nodetype(x) == Text]
        @test any(t -> contains(t, "Hello"), texts)
        @test any(t -> contains(t, "!"), texts)
        bolds = filter(x -> nodetype(x) == Element && tag(x) == "b", non_ws)
        @test length(bolds) == 1
        @test simple_value(bolds[1]) == "world"
    end
end

@testset "Roundtrip: file-based semantic preservation" begin
    all_files = filter(isfile, [
        joinpath(@__DIR__, "data", "xml.xsd"),
        joinpath(@__DIR__, "data", "kml.xsd"),
        joinpath(@__DIR__, "data", "books.xml"),
        joinpath(@__DIR__, "data", "example.kml"),
        joinpath(@__DIR__, "data", "simple_dtd.xml"),
        joinpath(@__DIR__, "data", "preserve.xml"),
    ])

    for path in all_files
        node = read(path, Node)
        temp = tempname() * ".xml"
        XML.write(temp, node)
        node2 = read(temp, Node)
        # Verify structural properties are preserved
        @test nodetype(node) == nodetype(node2)
        # Count non-whitespace elements
        count_elements(n) = sum(1 for c in children(n) if nodetype(c) == Element; init=0)
        @test count_elements(node) == count_elements(node2)
        rm(temp)
    end
end

#==============================================================================#
#                       PARSE Node{SubString{String}}                          #
#==============================================================================#
@testset "Parse with SubString{String}" begin
    xml = """<?xml version="1.0"?><root attr="val"><child>text</child></root>"""
    doc = parse(xml, Node{SubString{String}})
    @test nodetype(doc) == Document
    @test tag(doc[2]) == "root"
    @test doc[2]["attr"] == "val"
    # SubString values
    @test value(doc[2][1][1]) isa SubString{String}
end

#==============================================================================#
#                       COMPLEX DOCUMENT PARSING                               #
#==============================================================================#
@testset "Complex Document Parsing" begin
    @testset "books.xml" begin
        path = joinpath(@__DIR__, "data", "books.xml")
        isfile(path) || return
        doc = read(path, Node)
        @test nodetype(doc) == Document

        # Should have declaration + catalog
        decl_nodes = filter(x -> nodetype(x) == Declaration, children(doc))
        @test length(decl_nodes) == 1
        @test decl_nodes[1]["version"] == "1.0"

        el_nodes = filter(x -> nodetype(x) == Element, children(doc))
        @test length(el_nodes) == 1
        catalog = el_nodes[1]
        @test tag(catalog) == "catalog"

        # Catalog has 12 books
        books = filter(x -> nodetype(x) == Element, children(catalog))
        @test length(books) == 12

        # First book
        book1 = books[1]
        @test book1["id"] == "bk101"

        # Each book has: author, title, genre, price, publish_date, description
        book_children = filter(x -> nodetype(x) == Element, children(book1))
        book_tags = map(tag, book_children)
        @test "author" in book_tags
        @test "title" in book_tags
        @test "genre" in book_tags
        @test "price" in book_tags
        @test "publish_date" in book_tags
        @test "description" in book_tags

        author = first(filter(x -> tag(x) == "author", book_children))
        @test simple_value(author) == "Gambardella, Matthew"
    end

    @testset "simple_dtd.xml" begin
        path = joinpath(@__DIR__, "data", "simple_dtd.xml")
        isfile(path) || return
        doc = read(path, Node)
        @test nodetype(doc) == Document

        dtd_nodes = filter(x -> nodetype(x) == DTD, children(doc))
        @test length(dtd_nodes) == 1
        @test contains(value(dtd_nodes[1]), "ENTITY")
    end

    @testset "preserve.xml" begin
        path = joinpath(@__DIR__, "data", "preserve.xml")
        isfile(path) || return
        doc = read(path, Node)
        @test nodetype(doc) == Document

        root = filter(x -> nodetype(x) == Element, children(doc))[1]
        @test tag(root) == "root"
        @test root["xml:space"] == "preserve"

        child_els = filter(x -> nodetype(x) == Element, children(root))
        @test length(child_els) == 1
        @test tag(child_els[1]) == "child"
        @test child_els[1]["xml:space"] == "default"
    end

    @testset "example.kml" begin
        # example.kml is a valid KML sample with CDATA sections; the invalid
        # lowercase <![CData[ spelling it used to use is still rejected as malformed.
        path = joinpath(@__DIR__, "data", "example.kml")
        isfile(path) || return
        @test nodetype(read(path, Node)) == Document
        @test_throws ArgumentError parse("<r><![CData[x]]></r>", Node)
    end

    @testset "tv.dtd" begin
        path = joinpath(@__DIR__, "data", "tv.dtd")
        isfile(path) || return
        dtd_text = read(path, String)
        pd = parse_dtd("TVSCHEDULE [\n" * dtd_text * "\n]")
        @test pd.root == "TVSCHEDULE"

        @test length(pd.elements) == 10
        elem_names = map(e -> e.name, pd.elements)
        @test "TVSCHEDULE" in elem_names
        @test "CHANNEL" in elem_names
        @test "PROGRAMSLOT" in elem_names
        @test "TITLE" in elem_names

        @test length(pd.attributes) == 5
        attr_elements = map(a -> a.element, pd.attributes)
        @test "TVSCHEDULE" in attr_elements
        @test "CHANNEL" in attr_elements
        @test "TITLE" in attr_elements
    end
end

#==============================================================================#
#                        DTD PARSING (parse_dtd)                               #
#==============================================================================#
@testset "DTD Parsing (parse_dtd)" begin
    @testset "simple DTD with entities" begin
        path = joinpath(@__DIR__, "data", "simple_dtd.xml")
        isfile(path) || return
        doc = read(path, Node)
        dtd_node = first(filter(x -> nodetype(x) == DTD, children(doc)))
        pd = parse_dtd(dtd_node)
        @test pd.root == "note"
        @test length(pd.entities) == 3
        @test pd.entities[1].name == "nbsp"
        @test pd.entities[2].name == "writer"
        @test pd.entities[3].name == "copyright"
        @test pd.entities[2].value == "Writer: Donald Duck."
    end

    @testset "Unicode name in DTD" begin
        pd = parse_dtd("café [<!ELEMENT café (#PCDATA)>]")
        @test pd.root == "café"
        @test pd.elements[1].name == "café"
    end

    @testset "DTD with SYSTEM external ID" begin
        pd = parse_dtd("""root SYSTEM "root.dtd\"""")
        @test pd.root == "root"
        @test pd.system_id == "root.dtd"
        @test pd.public_id === nothing
    end

    @testset "DTD with PUBLIC external ID" begin
        pd = parse_dtd("""root PUBLIC "-//W3C//DTD XHTML 1.0//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\"""")
        @test pd.root == "root"
        @test pd.public_id == "-//W3C//DTD XHTML 1.0//EN"
        @test pd.system_id == "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"
    end

    @testset "DTD with ELEMENT declarations" begin
        pd = parse_dtd("""root [
<!ELEMENT root (child)>
<!ELEMENT child (#PCDATA)>
<!ELEMENT empty EMPTY>
<!ELEMENT any ANY>
]""")
        @test pd.root == "root"
        @test length(pd.elements) == 4
        @test pd.elements[1].name == "root"
        @test pd.elements[1].content == "(child)"
        @test pd.elements[2].name == "child"
        @test pd.elements[2].content == "(#PCDATA)"
        @test pd.elements[3].name == "empty"
        @test pd.elements[3].content == "EMPTY"
        @test pd.elements[4].name == "any"
        @test pd.elements[4].content == "ANY"
    end

    @testset "DTD with ATTLIST declarations (spec examples)" begin
        pd = parse_dtd("""root [
<!ATTLIST termdef id ID #REQUIRED name CDATA #IMPLIED>
<!ATTLIST list type (bullets|ordered|glossary) "ordered">
<!ATTLIST form method CDATA #FIXED "POST">
]""")
        @test length(pd.attributes) == 4
        @test pd.attributes[1].element == "termdef"
        @test pd.attributes[1].name == "id"
        @test pd.attributes[1].type == "ID"
        @test pd.attributes[1].default == "#REQUIRED"
        @test pd.attributes[2].name == "name"
        @test pd.attributes[2].type == "CDATA"
        @test pd.attributes[2].default == "#IMPLIED"
        @test pd.attributes[3].element == "list"
        @test pd.attributes[3].name == "type"
        @test pd.attributes[3].default == "\"ordered\""
        @test pd.attributes[4].element == "form"
        @test pd.attributes[4].name == "method"
        @test pd.attributes[4].default == "#FIXED \"POST\""
    end

    @testset "DTD with ENTITY declarations (spec examples)" begin
        pd = parse_dtd("""root [
<!ENTITY Pub-Status "This is a pre-release of the specification.">
<!ENTITY open-hatch SYSTEM "http://www.textuality.com/boilerplate/OpenHatch.xml">
<!ENTITY open-hatch2 PUBLIC "-//Textuality//TEXT Standard open-hatch boilerplate//EN" "http://www.textuality.com/boilerplate/OpenHatch.xml">
<!ENTITY % YN '"Yes"'>
]""")
        @test length(pd.entities) == 4
        @test pd.entities[1].name == "Pub-Status"
        @test pd.entities[1].value == "This is a pre-release of the specification."
        @test pd.entities[1].parameter == false

        @test pd.entities[2].name == "open-hatch"
        @test pd.entities[2].value === nothing
        @test contains(pd.entities[2].external_id, "SYSTEM")

        @test pd.entities[3].name == "open-hatch2"
        @test contains(pd.entities[3].external_id, "PUBLIC")

        @test pd.entities[4].name == "YN"
        @test pd.entities[4].parameter == true
    end

    @testset "DTD with NOTATION declarations (spec example)" begin
        pd = parse_dtd("""root [
<!NOTATION vrml PUBLIC "VRML 1.0">
<!NOTATION jpeg SYSTEM "image/jpeg">
]""")
        @test length(pd.notations) == 2
        @test pd.notations[1].name == "vrml"
        @test contains(pd.notations[1].external_id, "PUBLIC")
        @test pd.notations[2].name == "jpeg"
        @test contains(pd.notations[2].external_id, "SYSTEM")
    end

    @testset "parse_dtd from Node" begin
        dtd = DTD("root [<!ELEMENT root (#PCDATA)>]")
        pd = parse_dtd(dtd)
        @test pd.root == "root"
        @test length(pd.elements) == 1
    end

    @testset "parse_dtd errors on non-DTD node" begin
        @test_throws ErrorException parse_dtd(Element("x"))
    end

    @testset "parse_dtd gives a clear error on parameter-entity references" begin
        # PE references (%name;) are not expanded by this best-effort helper; the error explains
        # that, rather than surfacing an opaque internal BoundsError / position error.
        @test_throws "parameter-entity" parse_dtd("root [<!ELEMENT e %text;>]")
        # a PE-free DTD is unaffected
        @test parse_dtd("note [<!ELEMENT note (#PCDATA)>]").root == "note"
        # but a bare '%' that is NOT a %name; reference (here in an entity value) must not be
        # blamed: the real underlying error is surfaced, not the parameter-entity message.
        notation_err = try
            parse_dtd("root [ <!ENTITY pct \"100%\"> <!NOTATION n > ]")
            ""
        catch e
            sprint(showerror, e)
        end
        @test !isempty(notation_err)                       # the malformed NOTATION still errors
        @test !occursin("parameter-entity", notation_err)  # …with the true cause, not PE blame
    end

    @testset "complex DTD file (structure test)" begin
        # complex_dtd.xml uses parameter entity references (%text;) which parse_dtd does not
        # expand, so we just verify parsing the fixture works. It is an XML declaration plus an
        # internal-subset DOCTYPE with no root element, i.e. not a well-formed document — read it
        # with :lenient, since the default :structural now requires a root element (§2.1).
        path = joinpath(@__DIR__, "data", "complex_dtd.xml")
        isfile(path) || return
        doc = read(path, Node; wellformed=:lenient)
        dtd_node = first(filter(x -> nodetype(x) == DTD, children(doc)))
        @test nodetype(dtd_node) == DTD
        @test contains(value(dtd_node), "test")
        @test contains(value(dtd_node), "ELEMENT")
        @test contains(value(dtd_node), "ATTLIST")
        @test contains(value(dtd_node), "NOTATION")
        @test contains(value(dtd_node), "ENTITY")
    end
end

#==============================================================================#
#         XML 1.0 SPEC: ELEMENT TYPE DECLARATIONS (Section 3.2)                #
#==============================================================================#
@testset "Spec 3.2: Element Type Declarations" begin
    @testset "EMPTY content model" begin
        pd = parse_dtd("root [<!ELEMENT br EMPTY>]")
        @test pd.elements[1].content == "EMPTY"
    end

    @testset "ANY content model" begin
        pd = parse_dtd("root [<!ELEMENT container ANY>]")
        @test pd.elements[1].content == "ANY"
    end

    @testset "#PCDATA content model" begin
        pd = parse_dtd("root [<!ELEMENT text (#PCDATA)>]")
        @test pd.elements[1].content == "(#PCDATA)"
    end

    @testset "mixed content model" begin
        pd = parse_dtd("root [<!ELEMENT p (#PCDATA|emph)*>]")
        @test pd.elements[1].content == "(#PCDATA|emph)*"
    end

    @testset "sequence content model" begin
        pd = parse_dtd("root [<!ELEMENT spec (front, body, back?)>]")
        @test pd.elements[1].content == "(front, body, back?)"
    end

    @testset "choice content model" begin
        pd = parse_dtd("root [<!ELEMENT div1 (head, (p | list | note)*, div2*)>]")
        @test pd.elements[1].content == "(head, (p | list | note)*, div2*)"
    end
end

#==============================================================================#
#       XML 1.0 SPEC: ATTRIBUTE-LIST DECLARATIONS (Section 3.3)                #
#==============================================================================#
@testset "Spec 3.3: Attribute-List Declarations" begin
    @testset "ID attribute" begin
        pd = parse_dtd("root [<!ATTLIST el id ID #REQUIRED>]")
        @test pd.attributes[1].type == "ID"
        @test pd.attributes[1].default == "#REQUIRED"
    end

    @testset "CDATA attribute with default" begin
        pd = parse_dtd("""root [<!ATTLIST el name CDATA "default">]""")
        @test pd.attributes[1].type == "CDATA"
        @test pd.attributes[1].default == "\"default\""
    end

    @testset "enumerated attribute" begin
        pd = parse_dtd("""root [<!ATTLIST list type (bullets|ordered|glossary) "ordered">]""")
        @test contains(pd.attributes[1].type, "bullets")
        @test pd.attributes[1].default == "\"ordered\""
    end

    @testset "#IMPLIED attribute" begin
        pd = parse_dtd("root [<!ATTLIST el opt CDATA #IMPLIED>]")
        @test pd.attributes[1].default == "#IMPLIED"
    end

    @testset "#FIXED attribute" begin
        pd = parse_dtd("""root [<!ATTLIST el method CDATA #FIXED "POST">]""")
        @test pd.attributes[1].default == "#FIXED \"POST\""
    end

    @testset "NOTATION attribute type" begin
        pd = parse_dtd("root [<!ATTLIST fig notation NOTATION (jpeg|png) #IMPLIED>]")
        @test contains(pd.attributes[1].type, "NOTATION")
    end

    @testset "multiple attributes in one ATTLIST" begin
        pd = parse_dtd("""root [<!ATTLIST book
  id ID #REQUIRED
  isbn CDATA #IMPLIED
  format (hardcover|paperback|ebook) "paperback">]""")
        @test length(pd.attributes) == 3
        @test pd.attributes[1].name == "id"
        @test pd.attributes[2].name == "isbn"
        @test pd.attributes[3].name == "format"
    end
end

#==============================================================================#
#          XML 1.0 SPEC: ENTITY DECLARATIONS (Section 4.2)                     #
#==============================================================================#
@testset "Spec 4.2: Entity Declarations" begin
    @testset "internal general entity (spec example)" begin
        pd = parse_dtd("""root [<!ENTITY Pub-Status "This is a pre-release of the specification.">]""")
        @test pd.entities[1].name == "Pub-Status"
        @test pd.entities[1].value == "This is a pre-release of the specification."
        @test pd.entities[1].external_id === nothing
        @test pd.entities[1].parameter == false
    end

    @testset "external entity with SYSTEM (spec example)" begin
        pd = parse_dtd("""root [<!ENTITY open-hatch SYSTEM "http://www.textuality.com/boilerplate/OpenHatch.xml">]""")
        @test pd.entities[1].name == "open-hatch"
        @test pd.entities[1].value === nothing
        @test contains(pd.entities[1].external_id, "SYSTEM")
        @test contains(pd.entities[1].external_id, "http://www.textuality.com/boilerplate/OpenHatch.xml")
    end

    @testset "external entity with PUBLIC (spec example)" begin
        pd = parse_dtd("""root [<!ENTITY open-hatch PUBLIC "-//Textuality//TEXT Standard open-hatch boilerplate//EN" "http://www.textuality.com/boilerplate/OpenHatch.xml">]""")
        @test pd.entities[1].name == "open-hatch"
        @test contains(pd.entities[1].external_id, "PUBLIC")
    end

    @testset "parameter entity" begin
        pd = parse_dtd("""root [<!ENTITY % YN '"Yes"'>]""")
        @test pd.entities[1].name == "YN"
        @test pd.entities[1].parameter == true
    end
end

#==============================================================================#
#         XML 1.0 SPEC: NOTATION DECLARATIONS (Section 4.7)                    #
#==============================================================================#
@testset "Spec 4.7: Notation Declarations" begin
    @testset "NOTATION with PUBLIC (spec example)" begin
        pd = parse_dtd("""root [<!NOTATION vrml PUBLIC "VRML 1.0">]""")
        @test pd.notations[1].name == "vrml"
        @test contains(pd.notations[1].external_id, "PUBLIC")
        @test contains(pd.notations[1].external_id, "VRML 1.0")
    end

    @testset "NOTATION with SYSTEM" begin
        pd = parse_dtd("""root [<!NOTATION jpeg SYSTEM "image/jpeg">]""")
        @test pd.notations[1].name == "jpeg"
        @test contains(pd.notations[1].external_id, "SYSTEM")
    end
end

#==============================================================================#
#                        ERROR HANDLING                                        #
#==============================================================================#
@testset "Error Handling" begin
    @testset "mismatched tags" begin
        @test_throws ErrorException parse("<a></b>", Node)
    end

    @testset "unclosed tag" begin
        @test_throws ErrorException parse("<a><b></a>", Node)
    end

    @testset "closing tag with no open tag" begin
        @test_throws ErrorException parse("</a>", Node)
    end

    @testset "unclosed root element" begin
        @test_throws ErrorException parse("<root>", Node)
    end

    @testset "unterminated comment" begin
        @test_throws Exception parse("<root><!-- no end", Node)
    end

    @testset "unterminated CDATA" begin
        @test_throws Exception parse("<root><![CDATA[no end", Node)
    end

    @testset "unterminated PI" begin
        @test_throws Exception parse("<?pi no end", Node)
    end

    @testset "unterminated attribute value" begin
        @test_throws Exception parse("""<a b="no end""", Node)
    end

    @testset "truncated construct whose open token lands at EOF" begin
        # The open token consumes through end-of-input, so the body reader never ran: the Node
        # parser silently accepted these, and the lazy readers' value() indexed `nothing` (an
        # opaque MethodError). Each now raises a clear "unterminated ..." error.
        @test_throws Exception parse("<!--", Node)
        @test_throws Exception parse("<![CDATA[", Node)
        @test_throws Exception parse("<?pi", Node)
        @test_throws Exception parse("<root><!--", Node)
        @test_throws Exception parse("<root><![CDATA[", Node)
        # lazy readers re-tokenize on access — a clear error, not an opaque MethodError
        @test_throws Exception children(parse("<root><!--", LazyNode))[1]
        # complete constructs (including the empty comment <!---->) are unaffected
        @test nodetype(parse("<r><!--c--></r>", Node)) == Document
        @test nodetype(parse("<r><!----></r>", Node)) == Document
    end

    @testset "unterminated quoted string in a DOCTYPE uses the tokenizer error convention" begin
        # skip_quoted threw a bare ErrorException with no position; it now uses err(msg, pos)
        # like every other tokenizer error (ArgumentError with position context).
        @test_throws ArgumentError parse("<!DOCTYPE r SYSTEM \"abc", Node; wellformed=:lenient)
        @test_throws "tokenizer error at position" parse("<!DOCTYPE r SYSTEM \"abc", Node; wellformed=:lenient)
    end
end

#==============================================================================#
#                     ILL-FORMED XML (must error)                              #
#==============================================================================#
@testset "Ill-Formed XML" begin
    # ---- Tag structure ----
    @testset "mismatched close tag" begin
        @test_throws Exception parse("<a></b>", Node)
    end

    @testset "overlapping elements" begin
        @test_throws Exception parse("<a><b></a></b>", Node)
    end

    @testset "deeply mismatched nesting" begin
        @test_throws Exception parse("<a><b><c></b></c></a>", Node)
    end

    @testset "multiple unclosed tags" begin
        @test_throws Exception parse("<a><b><c>", Node)
    end

    @testset "close tag without open" begin
        @test_throws Exception parse("</a>", Node)
    end

    @testset "close tag after self-closing" begin
        @test_throws Exception parse("<a/></a>", Node)
    end

    @testset "nested close tag without open" begin
        @test_throws Exception parse("<root></inner></root>", Node)
    end

    # ---- Unterminated constructs ----
    @testset "unterminated open tag at EOF" begin
        @test_throws Exception parse("<root><unclosed", Node)
    end

    @testset "unterminated attribute value (double quote)" begin
        @test_throws Exception parse("""<a x="no end""", Node)
    end

    @testset "unterminated attribute value (single quote)" begin
        @test_throws Exception parse("<a x='no end", Node)
    end

    @testset "unterminated comment" begin
        @test_throws Exception parse("<!-- no end", Node)
    end

    @testset "unterminated CDATA" begin
        @test_throws Exception parse("<![CDATA[no end", Node)
    end

    @testset "unterminated processing instruction" begin
        @test_throws Exception parse("<?pi no end", Node)
    end

    @testset "unterminated DOCTYPE" begin
        @test_throws Exception parse("<!DOCTYPE x", Node)
    end

    # ---- Attribute errors ----
    @testset "duplicate attribute on element" begin
        @test_throws Exception parse("""<a x="1" x="2"/>""", Node)
    end

    @testset "duplicate attribute (different values)" begin
        @test_throws Exception parse("""<root attr="a" attr="b"></root>""", Node)
    end

    @testset "duplicate attribute in declaration" begin
        @test_throws Exception parse("""<?xml version="1.0" version="1.1"?><a/>""", Node)
    end

    @testset "attribute without value" begin
        @test_throws Exception parse("<a disabled/>", Node)
    end

    @testset "attribute with unquoted value" begin
        @test_throws Exception parse("<a x=hello/>", Node)
    end

    # ---- Tokenizer-level errors ----
    @testset "lone <" begin
        @test_throws Exception parse("<", Node)
    end

    @testset "lone < in text content" begin
        @test_throws Exception parse("<root>a < b</root>", Node)
    end

    @testset "tag with space before name" begin
        @test_throws Exception parse("< root/>", Node)
    end
end

#==============================================================================#
#                        UNICODE SUPPORT                                       #
#==============================================================================#
@testset "Unicode Support" begin
    @testset "Unicode in text content" begin
        doc = parse("<root>caf\u00e9 \u00f1 \u65e5\u672c\u8a9e</root>", Node)
        @test simple_value(doc[1]) == "caf\u00e9 \u00f1 \u65e5\u672c\u8a9e"
    end

    @testset "Unicode in attribute values" begin
        doc = parse("<root name=\"\u00fcber\"/>", Node)
        @test doc[1]["name"] == "\u00fcber"
    end

    @testset "Unicode in comments" begin
        doc = parse("<root><!-- h\u00e9llo --></root>", Node)
        @test value(doc[1][1]) == " h\u00e9llo "
    end

    @testset "CJK characters" begin
        doc = parse("<root>\u4e2d\u6587</root>", Node)
        @test simple_value(doc[1]) == "\u4e2d\u6587"
    end

    @testset "emoji in text" begin
        doc = parse("<root>\U0001f600\U0001f680</root>", Node)
        @test simple_value(doc[1]) == "\U0001f600\U0001f680"
    end

    @testset "Cyrillic characters" begin
        doc = parse("<root>\u041f\u0440\u0438\u0432\u0435\u0442</root>", Node)
        @test simple_value(doc[1]) == "\u041f\u0440\u0438\u0432\u0435\u0442"
    end

    @testset "Arabic characters" begin
        doc = parse("<root>\u0645\u0631\u062d\u0628\u0627</root>", Node)
        @test simple_value(doc[1]) == "\u0645\u0631\u062d\u0628\u0627"
    end

    # Non-ASCII characters in NAMES (element / attribute), not just content/values.
    @testset "Unicode in element names" begin
        doc = parse("<caf\u00e9>x</caf\u00e9>", Node)
        @test tag(doc[1]) == "caf\u00e9"
    end

    @testset "Unicode in attribute names" begin
        doc = parse("<root \u00fcber=\"1\"/>", Node)
        @test doc[1]["\u00fcber"] == "1"
        # a name *ending* in a multibyte char exercises the slice end-index (prevind)
        doc2 = parse("<root caf\u00e9=\"2\"/>", Node)
        @test doc2[1]["caf\u00e9"] == "2"
    end

    @testset "CJK element name" begin
        doc = parse("<\u65e5\u672c\u8a9e/>", Node)
        @test tag(doc[1]) == "\u65e5\u672c\u8a9e"
    end

    @testset "Unicode in PI target" begin
        doc = parse("<root><?caf\u00e9 data?></root>", Node)
        @test tag(doc[1][1]) == "caf\u00e9"
    end
end

#==============================================================================#
#                        EDGE CASES                                            #
#==============================================================================#
@testset "Edge Cases" begin
    @testset "document with only whitespace around root" begin
        doc = parse("  \n  <root/>\n  ", Node)
        # Parser preserves whitespace as Text nodes
        els = filter(x -> nodetype(x) == Element, children(doc))
        @test length(els) == 1
        @test tag(els[1]) == "root"
    end

    @testset "deeply nested elements" begin
        xml = "<a><b><c><d><e><f>deep</f></e></d></c></b></a>"
        doc = parse(xml, Node)
        @test simple_value(doc[1][1][1][1][1][1]) == "deep"
    end

    @testset "many siblings" begin
        items = join(["<item>$i</item>" for i in 1:100])
        xml = "<root>$items</root>"
        doc = parse(xml, Node)
        @test length(doc[1]) == 100
        @test simple_value(doc[1][1]) == "1"
        @test simple_value(doc[1][100]) == "100"
    end

    @testset "element with hyphens and dots in name" begin
        doc = parse("<my-element.name/>", Node)
        @test tag(doc[1]) == "my-element.name"
    end

    @testset "element with underscore in name" begin
        doc = parse("<_private/>", Node)
        @test tag(doc[1]) == "_private"
    end

    @testset "attribute with numeric value" begin
        doc = parse("""<x count="42"/>""", Node)
        @test doc[1]["count"] == "42"
    end

    @testset "empty text content" begin
        doc = parse("<root></root>", Node)
        @test isnothing(doc[1].children)
    end

    @testset "adjacent CDATA and text" begin
        doc = parse("<root>text<![CDATA[cdata]]>more</root>", Node)
        @test length(doc[1]) == 3
        @test value(doc[1][1]) == "text"
        @test value(doc[1][2]) == "cdata"
        @test value(doc[1][3]) == "more"
    end

    @testset "multiple CDATA sections" begin
        doc = parse("<root><![CDATA[a]]><![CDATA[b]]></root>", Node)
        @test length(doc[1]) == 2
        @test value(doc[1][1]) == "a"
        @test value(doc[1][2]) == "b"
    end

    @testset "comment between elements" begin
        doc = parse("<root><a/><!-- between --><b/></root>", Node)
        @test length(doc[1]) == 3
        @test nodetype(doc[1][2]) == Comment
    end

    @testset "PI between elements" begin
        doc = parse("<root><a/><?pi data?><b/></root>", Node)
        @test length(doc[1]) == 3
        @test nodetype(doc[1][2]) == ProcessingInstruction
    end

    @testset "all node types in one document" begin
        xml = """<?xml version="1.0"?>
<!DOCTYPE root SYSTEM "root.dtd">
<!-- comment -->
<?pi data?>
<root>
  text
  <child attr="val"/>
  <!-- inner comment -->
  <![CDATA[cdata]]>
  <?inner-pi inner data?>
</root>"""
        doc = parse(xml, Node)
        types = map(nodetype, children(doc))
        @test Declaration in types
        @test DTD in types
        @test Comment in types
        @test ProcessingInstruction in types
        @test Element in types
    end

    @testset "very long attribute value" begin
        long_val = repeat("a", 10000)
        doc = parse("""<x attr="$(long_val)"/>""", Node)
        @test doc[1]["attr"] == long_val
    end

    @testset "very long text content" begin
        long_text = repeat("hello ", 10000)
        doc = parse("<root>$(long_text)</root>", Node)
        @test simple_value(doc[1]) == long_text
    end

    @testset "CDATA with ]] but not followed by >" begin
        doc = parse("<root><![CDATA[a]]b]]></root>", Node)
        @test value(doc[1][1]) == "a]]b"
    end
end

#==============================================================================#
#                  SPEC EXAMPLES: FULL DOCUMENTS                               #
#==============================================================================#
@testset "Full Spec-Like Documents" begin
    @testset "spec section 2.1: minimal document" begin
        xml = """<?xml version="1.0"?>
<greeting>Hello, world!</greeting>"""
        doc = parse(xml, Node)
        @test nodetype(doc) == Document
        @test simple_value(doc[end]) == "Hello, world!"
    end

    @testset "spec section 2.8: document with external DTD" begin
        xml = """<?xml version="1.0"?>
<!DOCTYPE greeting SYSTEM "hello.dtd">
<greeting>Hello, world!</greeting>"""
        doc = parse(xml, Node)
        # Filter out whitespace text nodes to check structure
        typed = filter(x -> nodetype(x) != Text, children(doc))
        @test length(typed) == 3
        @test nodetype(typed[1]) == Declaration
        @test nodetype(typed[2]) == DTD
        @test nodetype(typed[3]) == Element
    end

    @testset "spec: document with internal subset" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE greeting [
  <!ELEMENT greeting (#PCDATA)>
]>
<greeting>Hello, world!</greeting>"""
        doc = parse(xml, Node)
        typed = filter(x -> nodetype(x) != Text, children(doc))
        @test typed[1]["encoding"] == "UTF-8"
        @test nodetype(typed[2]) == DTD
        pd = parse_dtd(typed[2])
        @test pd.root == "greeting"
        @test length(pd.elements) == 1
        @test pd.elements[1].name == "greeting"
        @test pd.elements[1].content == "(#PCDATA)"
        @test simple_value(typed[3]) == "Hello, world!"
    end

    @testset "typical HTML5-like doctype" begin
        xml = """<!DOCTYPE html><html><head><title>Test</title></head><body><p>Content</p></body></html>"""
        doc = parse(xml, Node)
        @test nodetype(doc[1]) == DTD
        @test value(doc[1]) == "html"
        @test tag(doc[2]) == "html"
    end

    @testset "SVG document" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <circle cx="50" cy="50" r="40" fill="red"/>
  <text x="50" y="50">Hello SVG</text>
</svg>"""
        doc = parse(xml, Node)
        svg = doc[end]
        @test tag(svg) == "svg"
        @test svg["xmlns"] == "http://www.w3.org/2000/svg"
        @test svg["width"] == "100"

        elements = filter(x -> nodetype(x) == Element, children(svg))
        @test length(elements) == 2
        @test tag(elements[1]) == "circle"
        @test elements[1]["fill"] == "red"
        @test tag(elements[2]) == "text"
        @test value(elements[2][1]) == "Hello SVG"
    end

    @testset "SOAP-like envelope" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
  <soap:Header/>
  <soap:Body>
    <m:GetPrice xmlns:m="http://www.example.org/stock">
      <m:StockName>IBM</m:StockName>
    </m:GetPrice>
  </soap:Body>
</soap:Envelope>"""
        doc = parse(xml, Node)
        env = doc[end]
        @test tag(env) == "soap:Envelope"
        elements = filter(x -> nodetype(x) == Element, children(env))
        @test tag(elements[1]) == "soap:Header"
        @test tag(elements[2]) == "soap:Body"
    end

    @testset "RSS-like feed" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Example Feed</title>
    <link>http://example.com</link>
    <description>An example RSS feed</description>
    <item>
      <title>Item 1</title>
      <link>http://example.com/1</link>
    </item>
    <item>
      <title>Item 2</title>
      <link>http://example.com/2</link>
    </item>
  </channel>
</rss>"""
        doc = parse(xml, Node)
        rss = doc[end]
        @test tag(rss) == "rss"
        @test rss["version"] == "2.0"
        channel = first(filter(x -> nodetype(x) == Element, children(rss)))
        @test tag(channel) == "channel"
        items = filter(x -> nodetype(x) == Element && tag(x) == "item", children(channel))
        @test length(items) == 2
    end

    @testset "Atom-like feed" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example Feed</title>
  <entry>
    <title>Atom-Powered Robots Run Amok</title>
    <link href="http://example.org/2003/12/13/atom03"/>
    <id>urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a</id>
    <updated>2003-12-13T18:30:02Z</updated>
    <summary>Some text.</summary>
  </entry>
</feed>"""
        doc = parse(xml, Node)
        feed = doc[end]
        @test tag(feed) == "feed"
        @test feed["xmlns"] == "http://www.w3.org/2005/Atom"
        entries = filter(x -> nodetype(x) == Element && tag(x) == "entry", children(feed))
        @test length(entries) == 1
    end

    @testset "MathML-like document" begin
        xml = """<math xmlns="http://www.w3.org/1998/Math/MathML">
  <mrow>
    <msup>
      <mi>x</mi>
      <mn>2</mn>
    </msup>
    <mo>+</mo>
    <mn>1</mn>
  </mrow>
</math>"""
        doc = parse(xml, Node)
        math = doc[1]
        @test tag(math) == "math"
        @test math["xmlns"] == "http://www.w3.org/1998/Math/MathML"
    end

    @testset "document with processing instructions and comments mixed" begin
        xml = """<?xml version="1.0"?>
<!-- This is a comment before the root -->
<?xml-stylesheet type="text/css" href="style.css"?>
<root>
  <!-- inner comment -->
  <child/>
  <?pi-inside data?>
</root>
<!-- trailing comment -->"""
        doc = parse(xml, Node)
        types = map(nodetype, children(doc))
        @test count(==(Comment), types) == 2
        @test count(==(ProcessingInstruction), types) >= 1
        @test count(==(Element), types) == 1
    end
end

#==============================================================================#
#                        SHOW / DISPLAY                                        #
#==============================================================================#
@testset "Show (REPL display)" begin
    @testset "show Text" begin
        t = Text("hello")
        s = sprint(show, t)
        @test contains(s, "Text")
        @test contains(s, "hello")
    end

    @testset "show Element" begin
        el = Element("div"; class="main")
        s = sprint(show, el)
        @test contains(s, "Element")
        @test contains(s, "<div")
        @test contains(s, "class")
    end

    @testset "show Comment" begin
        c = Comment(" test ")
        s = sprint(show, c)
        @test contains(s, "Comment")
        @test contains(s, "<!--")
    end

    @testset "show CData" begin
        cd = CData("data")
        s = sprint(show, cd)
        @test contains(s, "CData")
        @test contains(s, "<![CDATA[")
    end

    @testset "show DTD" begin
        d = DTD("html")
        s = sprint(show, d)
        @test contains(s, "DTD")
        @test contains(s, "<!DOCTYPE")
    end

    @testset "show Declaration" begin
        decl = Declaration(; version="1.0")
        s = sprint(show, decl)
        @test contains(s, "Declaration")
        @test contains(s, "<?xml")
    end

    @testset "show ProcessingInstruction" begin
        pi = ProcessingInstruction("target", "data")
        s = sprint(show, pi)
        @test contains(s, "ProcessingInstruction")
        @test contains(s, "<?target")
    end

    @testset "show Document" begin
        doc = Document(Element("root"))
        s = sprint(show, doc)
        @test contains(s, "Document")
        @test contains(s, "1 child")
    end

    @testset "show Element with children count" begin
        el = Element("div", Element("a"), Element("b"), Element("c"))
        s = sprint(show, el)
        @test contains(s, "3 children")
    end

    @testset "text/xml MIME" begin
        el = Element("p", "hello")
        s = sprint(show, MIME("text/xml"), el)
        @test s == "<p>hello</p>"
    end
end

#==============================================================================#
#                    SHOW (text/xml MIME) ROUNDTRIP                             #
#==============================================================================#
@testset "text/xml MIME output" begin
    doc = Document(
        Declaration(; version="1.0"),
        Element("root", Element("child", "text"))
    )
    xml_str = sprint(show, MIME("text/xml"), doc)
    @test contains(xml_str, "<?xml")
    @test contains(xml_str, "<root>")
    @test contains(xml_str, "<child>text</child>")
    # Verify it's parseable
    doc2 = parse(xml_str, Node)
    @test nodetype(doc2) == Document
    root = first(filter(x -> nodetype(x) == Element, children(doc2)))
    @test tag(root) == "root"
    child = first(filter(x -> nodetype(x) == Element, children(root)))
    @test simple_value(child) == "text"
end

#==============================================================================#
#                    CONSTRUCTION → WRITE → PARSE ROUNDTRIP                    #
#==============================================================================#
@testset "Construction → Write → Parse" begin
    @testset "simple element: write then parse preserves semantics" begin
        el = Element("greeting", "Hello, world!")
        xml = XML.write(Document(el))
        doc2 = parse(xml, Node)
        @test simple_value(doc2[1]) == "Hello, world!"
    end

    @testset "element with attributes: write then parse preserves attributes" begin
        el = Element("item"; id="1", class="active")
        xml = XML.write(Document(el))
        doc2 = parse(xml, Node)
        @test doc2[1]["id"] == "1"
        @test doc2[1]["class"] == "active"
    end

    @testset "single-child text elements roundtrip" begin
        doc = Document(Element("root", "text"))
        xml = XML.write(doc)
        doc2 = parse(xml, Node)
        @test doc == doc2
    end

    @testset "self-closing elements roundtrip" begin
        doc = Document(Element("root"))
        xml = XML.write(doc)
        doc2 = parse(xml, Node)
        @test doc == doc2
    end

    @testset "all node types survive write → parse" begin
        doc = Document(
            Declaration(; version="1.0"),
            Comment(" header "),
            Element("root",
                Element("child", "text"),
                CData("raw <data>"),
                Comment(" inner "),
                ProcessingInstruction("pi", "content")
            )
        )
        xml = XML.write(doc)
        doc2 = parse(xml, Node)
        typed = filter(x -> nodetype(x) != Text, children(doc2))
        @test count(==(Declaration), map(nodetype, typed)) == 1
        @test count(==(Comment), map(nodetype, typed)) == 1
        @test count(==(Element), map(nodetype, typed)) == 1
        root = first(filter(x -> nodetype(x) == Element, typed))
        inner = filter(x -> nodetype(x) != Text, children(root))
        inner_types = map(nodetype, inner)
        @test Element in inner_types
        @test CData in inner_types
        @test Comment in inner_types
        @test ProcessingInstruction in inner_types
    end

    @testset "special characters in text roundtrip" begin
        el = Element("p", "a < b & c > d ' e \" f")
        xml = XML.write(Document(el))
        doc2 = parse(xml, Node)
        @test simple_value(doc2[1]) == "a < b & c > d ' e \" f"
    end

    @testset "special characters in attributes roundtrip" begin
        el = Element("x"; data="a&b<c>d'e\"f")
        xml = XML.write(Document(el))
        doc2 = parse(xml, Node)
        @test doc2[1]["data"] == "a&b<c>d'e\"f"
    end
end

#==============================================================================#
#                        KML-LIKE DOCUMENT                                     #
#==============================================================================#
@testset "KML-like Document" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>KML Sample</name>
    <Placemark>
      <name>Simple placemark</name>
      <description>Attached to the ground.</description>
      <Point>
        <coordinates>-122.0822035,37.4220033612141,0</coordinates>
      </Point>
    </Placemark>
  </Document>
</kml>"""
    doc = parse(xml, Node)
    kml = doc[end]
    @test tag(kml) == "kml"
    @test kml["xmlns"] == "http://www.opengis.net/kml/2.2"

    document = first(filter(x -> nodetype(x) == Element, children(kml)))
    @test tag(document) == "Document"

    name = first(filter(x -> nodetype(x) == Element && tag(x) == "name", children(document)))
    @test simple_value(name) == "KML Sample"

    pm = first(filter(x -> nodetype(x) == Element && tag(x) == "Placemark", children(document)))
    pm_name = first(filter(x -> nodetype(x) == Element && tag(x) == "name", children(pm)))
    @test simple_value(pm_name) == "Simple placemark"
end

#==============================================================================#
#                        XHTML-LIKE DOCUMENT                                   #
#==============================================================================#
@testset "XHTML-like Document" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title>XHTML Test</title>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
  </head>
  <body>
    <h1>Hello World</h1>
    <p>This is a <strong>test</strong> of XHTML.</p>
    <br/>
    <img src="image.png" alt="An image"/>
  </body>
</html>"""
    doc = parse(xml, Node)
    typed = filter(x -> nodetype(x) != Text, children(doc))
    @test nodetype(typed[1]) == Declaration
    @test nodetype(typed[2]) == DTD
    @test contains(value(typed[2]), "PUBLIC")

    html = first(filter(x -> nodetype(x) == Element, children(doc)))
    @test tag(html) == "html"
    @test html["xmlns"] == "http://www.w3.org/1999/xhtml"

    head_el = first(filter(x -> nodetype(x) == Element && tag(x) == "head", children(html)))
    title_el = first(filter(x -> nodetype(x) == Element && tag(x) == "title", children(head_el)))
    @test simple_value(title_el) == "XHTML Test"

    body_el = first(filter(x -> nodetype(x) == Element && tag(x) == "body", children(html)))
    h1_el = first(filter(x -> nodetype(x) == Element && tag(x) == "h1", children(body_el)))
    @test simple_value(h1_el) == "Hello World"

    # Verify write produces valid XML that can be re-parsed
    xml2 = XML.write(doc)
    doc2 = parse(xml2, Node)
    @test nodetype(doc2) == Document
end

#==============================================================================#
#                    PLIST-LIKE DOCUMENT                                        #
#==============================================================================#
@testset "plist-like Document" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleName</key>
    <string>MyApp</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
  </dict>
</plist>"""
    doc = parse(xml, Node)
    plist = doc[end]
    @test tag(plist) == "plist"
    @test plist["version"] == "1.0"

    dict = first(filter(x -> nodetype(x) == Element, children(plist)))
    @test tag(dict) == "dict"

    elements = filter(x -> nodetype(x) == Element, children(dict))
    keys_found = [simple_value(e) for e in elements if tag(e) == "key"]
    @test "CFBundleName" in keys_found
    @test "CFBundleVersion" in keys_found
end

#==============================================================================#
#                    MAVEN POM-LIKE DOCUMENT                                   #
#==============================================================================#
@testset "Maven POM-like Document" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>my-app</artifactId>
  <version>1.0-SNAPSHOT</version>
  <dependencies>
    <dependency>
      <groupId>junit</groupId>
      <artifactId>junit</artifactId>
      <version>4.13.2</version>
      <scope>test</scope>
    </dependency>
  </dependencies>
</project>"""
    doc = parse(xml, Node)
    project = doc[end]
    @test tag(project) == "project"

    elements = filter(x -> nodetype(x) == Element, children(project))
    version = first(filter(x -> tag(x) == "version", elements))
    @test simple_value(version) == "1.0-SNAPSHOT"

    deps = first(filter(x -> tag(x) == "dependencies", elements))
    dep_list = filter(x -> nodetype(x) == Element, children(deps))
    @test length(dep_list) == 1
    @test tag(dep_list[1]) == "dependency"
end

#==============================================================================#
#                    GITHUB ISSUES REGRESSION TESTS                            #
#==============================================================================#
@testset "GitHub Issues" begin

    #--- Issue #7: attribute order should not affect equality ---
    @testset "#7: attribute-order-insensitive ==" begin
        a = Element("x"; first="1", second="2")
        b = Element("x"; second="2", first="1")
        @test a == b

        # Same attrs same order still works
        c = Element("x"; a="1", b="2")
        d = Element("x"; a="1", b="2")
        @test c == d

        # Different values are still not equal
        @test Element("x"; a="1") != Element("x"; a="2")

        # Different attr names are not equal
        @test Element("x"; a="1") != Element("x"; b="1")

        # Different number of attrs
        @test Element("x"; a="1") != Element("x"; a="1", b="2")

        # Parsed elements with same attrs in different order
        doc1 = parse("""<x a="1" b="2"/>""", Node)
        doc2 = parse("""<x b="2" a="1"/>""", Node)
        @test doc1[1] == doc2[1]

        # No attrs vs empty attrs (both are "no attributes")
        @test Element("x") == Element("x")
    end

    #--- Issue #17: numeric character references ---
    @testset "#17: numeric character references (&#decimal; and &#xHex;)" begin
        # Decimal character references
        @test unescape("&#60;") == "<"
        @test unescape("&#62;") == ">"
        @test unescape("&#38;") == "&"
        @test unescape("&#39;") == "'"
        @test unescape("&#34;") == "\""

        # Hex character references (lowercase x)
        @test unescape("&#x3c;") == "<"
        @test unescape("&#x3C;") == "<"
        @test unescape("&#x3e;") == ">"
        @test unescape("&#x26;") == "&"
        @test unescape("&#x27;") == "'"
        @test unescape("&#x22;") == "\""

        # Uppercase X also works
        @test unescape("&#X41;") == "A"

        # Unicode character references
        @test unescape("&#x41;") == "A"
        @test unescape("&#65;") == "A"
        @test unescape("&#x00e9;") == "\u00e9"  # é
        @test unescape("&#233;") == "\u00e9"     # é
        @test unescape("&#x4e2d;") == "\u4e2d"   # 中
        @test unescape("&#x1f600;") == "\U0001f600"  # 😀

        # Mixed with named entities
        @test unescape("&amp;&#60;&lt;") == "&<<"
        @test unescape("&#60;tag&#62;") == "<tag>"

        # Single-pass: a resolved character reference is never re-scanned as a new
        # entity. A numeric ref to '&' must NOT combine with a following "amp;"/"lt;".
        @test unescape("&#38;amp;") == "&amp;"
        @test unescape("&#x26;amp;") == "&amp;"
        @test unescape("&#38;lt;") == "&lt;"
        @test unescape("&#38;#65;") == "&#65;"   # resolved '&' must not start "&#65;"
        @test unescape("&#65;amp;") == "Aamp;"   # non-'&' ref leaves the tail literal
        # ...and through the Node reader end-to-end
        @test simple_value(parse("<r>&#38;amp;</r>", Node)[1]) == "&amp;"

        # In parsed XML text
        doc = parse("<root>&#60;hello&#62;</root>", Node)
        @test simple_value(doc[1]) == "<hello>"

        # In parsed XML attributes
        doc = parse("""<x a="&#60;&#62;"/>""", Node)
        @test doc[1]["a"] == "<>"

        # Non-breaking space
        @test unescape("&#xA0;") == "\u00a0"
        @test unescape("&#160;") == "\u00a0"

        # Invalid numeric reference preserved verbatim
        @test unescape("&#xZZZ;") == "&#xZZZ;"

        # Named entity references that aren't predefined are preserved verbatim
        @test unescape("&foo;") == "&foo;"

        # Ampersand without semicolon is preserved
        @test unescape("a & b") == "a & b"
    end

    #--- Issue #33: empty attributes consistency ---
    @testset "#33: empty attributes [] vs nothing" begin
        # Constructed elements have empty Vector for attrs
        a = Element("x")
        # Parsed elements with no attrs have nothing
        b = parse("<x/>", Node)[1]
        # They should compare equal via _eq / _attrs_eq
        @test a == b
    end

    #--- Issue #35: write → parse preserves structure ---
    @testset "#35: write then parse preserves structure" begin
        doc = Document(
            Declaration(; version="1.0"),
            Element("root",
                Element("child", "text"),
                Element("empty")
            )
        )
        xml = XML.write(doc)
        doc2 = parse(xml, Node)
        root = first(filter(x -> nodetype(x) == Element, children(doc2)))
        child_elements = filter(x -> nodetype(x) == Element, children(root))
        @test length(child_elements) == 2
        @test tag(child_elements[1]) == "child"
        @test tag(child_elements[2]) == "empty"
    end

    #--- Issue #50: Base.get with default ---
    @testset "#50: Base.get(node, key, default)" begin
        el = parse("""<x a="1" b="2"/>""", Node)[1]

        # Existing keys return their values
        @test get(el, "a", "default") == "1"
        @test get(el, "b", "default") == "2"

        # Non-existing key returns default
        @test get(el, "c", "default") == "default"
        @test get(el, "c", nothing) === nothing

        # Works on elements with no attributes
        el2 = parse("<x/>", Node)[1]
        @test get(el2, "a", "nope") == "nope"

        # Works on constructed elements
        el3 = Element("x"; foo="bar")
        @test get(el3, "foo", "default") == "bar"
        @test get(el3, "baz", "default") == "default"
    end

    #--- Issue #52: escape double-escapes (expected behavior) ---
    @testset "#52: escape is not idempotent (by design)" begin
        @test escape("&") == "&amp;"
        @test escape("&amp;") == "&amp;amp;"  # double-escaping is correct
    end

    #--- Issue #53: unescape works correctly ---
    @testset "#53: unescape works correctly on parsed content" begin
        doc = parse("<root>&amp;</root>", Node)
        @test simple_value(doc[1]) == "&"
        doc = parse("<root>&lt;tag&gt;</root>", Node)
        @test simple_value(doc[1]) == "<tag>"
    end
end

#==============================================================================#
#                        TREE NAVIGATION: parent, depth, siblings              #
#==============================================================================#
@testset "Tree Navigation" begin
    doc = parse("<root><a><a1/><a2/></a><b/><c><c1><c1a/></c1></c></root>", Node)
    root = doc[1]
    a = root[1]
    a1 = a[1]
    a2 = a[2]
    b = root[2]
    c = root[3]
    c1 = c[1]
    c1a = c1[1]

    @testset "parent" begin
        @test parent(root, doc) === doc
        @test parent(a, doc) === root
        @test parent(a1, doc) === a
        @test parent(c1a, doc) === c1
        @test parent(b, root) === root
        @test_throws ErrorException parent(doc, doc)  # root has no parent
        @test_throws ErrorException parent(Element("x"), doc)  # not in tree
    end

    @testset "depth" begin
        @test depth(doc, doc) == 0
        @test depth(root, doc) == 1
        @test depth(a, doc) == 2
        @test depth(a1, doc) == 3
        @test depth(c1a, doc) == 4
        @test depth(b, root) == 1
        @test_throws ErrorException depth(Element("x"), doc)
    end

    @testset "siblings" begin
        @test siblings(a, doc) == [b, c]
        @test siblings(b, doc) == [a, c]
        @test siblings(a1, doc) == [a2]
        @test siblings(a2, doc) == [a1]
        @test isempty(siblings(c1, doc))
        @test_throws ErrorException siblings(doc, doc)  # root has no parent
    end

    @testset "1-arg parent/depth errors" begin
        @test_throws ErrorException parent(a)
        @test_throws ErrorException depth(a)
    end
end

#==============================================================================#
#                        DEPRECATIONS / REMOVED API                            #
#==============================================================================#
@testset "Deprecations and Removed API" begin
    node = Element("test")
    node2 = Element("other")

    @testset "XML.next errors" begin
        @test_throws ErrorException XML.next(node)
    end

    @testset "XML.prev errors" begin
        @test_throws ErrorException XML.prev(node)
    end

    @testset "XML.nodes_equal errors" begin
        @test_throws ErrorException XML.nodes_equal(node, node2)
    end

    @testset "XML.escape! errors" begin
        @test_throws ErrorException XML.escape!(node)
        @test_throws ErrorException XML.escape!(node, false)
    end

    @testset "XML.unescape! errors" begin
        @test_throws ErrorException XML.unescape!(node)
        @test_throws ErrorException XML.unescape!(node, false)
    end

    @testset "XML.Raw errors" begin
        @test_throws ErrorException XML.Raw()
        @test_throws ErrorException XML.Raw("arg")
    end

    @testset "simplevalue binding redirects to simple_value" begin
        el = Element("x", "val")
        @test XML.simplevalue(el) == simple_value(el)
    end
end

#==============================================================================#
#                              XPATH                                           #
#==============================================================================#
@testset "XPath" begin
    doc = parse("""<root>
        <users>
            <user id="1" role="admin"><name>Alice</name></user>
            <user id="2" role="user"><name>Bob</name></user>
            <user id="3" role="admin"><name>Carol</name></user>
        </users>
        <settings><theme>dark</theme></settings>
    </root>""", Node)

    @testset "absolute path" begin
        results = xpath(doc, "/root/users/user")
        @test length(results) == 3
        @test all(n -> tag(n) == "user", results)
    end

    @testset "single child" begin
        results = xpath(doc, "/root/settings/theme")
        @test length(results) == 1
        @test tag(results[1]) == "theme"
    end

    @testset "positional predicate [n]" begin
        results = xpath(doc, "/root/users/user[1]")
        @test length(results) == 1
        @test results[1]["id"] == "1"

        results = xpath(doc, "/root/users/user[3]")
        @test length(results) == 1
        @test results[1]["id"] == "3"
    end

    @testset "[last()]" begin
        results = xpath(doc, "/root/users/user[last()]")
        @test length(results) == 1
        @test results[1]["id"] == "3"
    end

    @testset "out of bounds predicate" begin
        results = xpath(doc, "/root/users/user[99]")
        @test isempty(results)
    end

    @testset "unsupported axis fails fast (not a silent empty result)" begin
        # axis::test syntax (child::, self::, descendant::, following-sibling::, parent::, ...) is
        # out of this subset — it must error, not lex as a literal element name matching nothing.
        @test_throws Exception xpath(doc, "child::users")
        @test_throws Exception xpath(doc, "/root/child::users")
        @test_throws Exception xpath(doc, "self::root")
        @test_throws Exception xpath(doc, "descendant::user")
        @test_throws Exception xpath(doc, "following-sibling::user")
        @test_throws Exception xpath(doc, "parent::node()")
        # a single ":" (a namespaced name) is NOT an axis — it stays a normal name test
        @test isempty(xpath(doc, "ns:missing"))
    end

    @testset "README example: doc[1] is the root (doc[end] is the trailing-whitespace Text)" begin
        rdoc = parse("""
<root>
  <a id="1"><b>hello</b></a>
  <a id="2"><b>world</b></a>
</root>
""", Node)
        root = rdoc[1]
        @test nodetype(root) == Element && tag(root) == "root"
        @test length(xpath(root, "//b")) == 2
        @test length(xpath(root, "a[@id='2']/b")) == 1
        @test length(xpath(root, "a[1]")) == 1
        @test length(xpath(root, "//b/text()")) == 2
        # the documented pitfall: doc[end] is the trailing whitespace Text node, not <root>
        @test nodetype(rdoc[end]) == Text
    end

    @testset "has-attribute predicate [@attr]" begin
        results = xpath(doc, "/root/users/user[@role]")
        @test length(results) == 3
    end

    @testset "attribute-value predicate [@attr='v']" begin
        results = xpath(doc, "/root/users/user[@role='admin']")
        @test length(results) == 2
        ids = sort([n["id"] for n in results])
        @test ids == ["1", "3"]
    end

    @testset "attribute-value with double quotes" begin
        results = xpath(doc, """/root/users/user[@id="2"]""")
        @test length(results) == 1
        @test results[1]["id"] == "2"
    end

    @testset "descendant //" begin
        results = xpath(doc, "//name")
        @test length(results) == 3
        @test all(n -> tag(n) == "name", results)
    end

    @testset "// with predicate" begin
        results = xpath(doc, "//user[@role='admin']/name")
        @test length(results) == 2
    end

    @testset "wildcard *" begin
        results = xpath(doc, "/root/*")
        @test length(results) == 2
        @test Set(tag.(results)) == Set(["users", "settings"])
    end

    @testset "text()" begin
        results = xpath(doc, "/root/settings/theme/text()")
        @test length(results) == 1
        @test value(results[1]) == "dark"
    end

    @testset "node()" begin
        results = xpath(doc, "/root/users/user[1]/node()")
        @test length(results) >= 1
    end

    @testset "attribute selection @attr" begin
        results = xpath(doc, "//user/@id")
        @test length(results) == 3
        vals = sort([value(n) for n in results])
        @test vals == ["1", "2", "3"]
    end

    @testset "self ." begin
        results = xpath(doc, ".")
        @test length(results) == 1
        @test results[1] === doc
    end

    @testset "no match returns empty" begin
        @test isempty(xpath(doc, "/root/nonexistent"))
        @test isempty(xpath(doc, "//nonexistent"))
    end

    @testset "empty expression" begin
        @test isempty(xpath(doc, ""))
    end

    @testset "deep // with path" begin
        results = xpath(doc, "//theme/text()")
        @test length(results) == 1
        @test value(results[1]) == "dark"
    end

    @testset "error: unterminated predicate" begin
        @test_throws ErrorException xpath(doc, "/root/user[1")
    end

    @testset "error: unsupported predicate" begin
        @test_throws ErrorException xpath(doc, "/root/user[position()>1]")
    end

    @testset "self-closing elements" begin
        doc2 = parse("<root><a/><b/><c/></root>", Node)
        @test length(xpath(doc2, "/root/*")) == 3
    end

    @testset "relative path" begin
        root = xpath(doc, "/root")[1]
        results = xpath(root, "users/user")
        @test length(results) == 3
    end

    @testset ".. parent navigation" begin
        # /root/users/user[1]/.. goes back to <users>
        results = xpath(doc, "/root/users/user[1]/..")
        @test length(results) == 1
        @test tag(results[1]) == "users"
    end

    @testset ".. in mid-path" begin
        # /root/users/.. should go back to root
        results = xpath(doc, "/root/users/..")
        @test length(results) == 1
        @test tag(results[1]) == "root"
    end

    @testset "// mid-path" begin
        # /root//name finds all <name> elements anywhere under root
        results = xpath(doc, "/root//name")
        @test length(results) == 3
        @test all(n -> tag(n) == "name", results)
    end

    @testset "// with wildcard //*" begin
        doc2 = parse("<r><a><b/></a><c/></r>", Node)
        results = xpath(doc2, "//*")
        tags = [tag(n) for n in results if nodetype(n) === Element]
        @test "r" in tags
        @test "a" in tags
        @test "b" in tags
        @test "c" in tags
    end

    @testset "// with text()" begin
        results = xpath(doc, "//text()")
        @test length(results) >= 3  # at least Alice, Bob, Carol
        vals = [value(n) for n in results]
        @test "Alice" in vals
        @test "Bob" in vals
        @test "dark" in vals
    end

    @testset "multiple // segments" begin
        results = xpath(doc, "//users//name")
        @test length(results) == 3
        @test all(n -> tag(n) == "name", results)
    end

    @testset "chained predicates" begin
        results = xpath(doc, "/root/users/user[@role='admin'][1]")
        @test length(results) == 1
        @test results[1]["id"] == "1"
    end

    @testset "@attr with no match" begin
        results = xpath(doc, "//user/@nonexistent")
        @test isempty(results)
    end

    @testset "namespaced tag" begin
        doc2 = parse("""<root xmlns:ns="http://example.com"><ns:item>val</ns:item></root>""", Node)
        results = xpath(doc2, "/root/ns:item")
        @test length(results) == 1
        @test tag(results[1]) == "ns:item"
    end

    @testset "whitespace in expression" begin
        results = xpath(doc, " / root / users / user ")
        @test length(results) == 3
    end

    @testset "error: empty @" begin
        @test_throws ErrorException xpath(doc, "/root/@")
    end

    @testset "error: unknown function" begin
        @test_throws ErrorException xpath(doc, "/root/foo()")
    end

    @testset "error: unexpected character" begin
        @test_throws ErrorException xpath(doc, "/root/!bad")
    end

    @testset "deep nesting" begin
        doc2 = parse("<a><b><c><d><e>deep</e></d></c></b></a>", Node)
        results = xpath(doc2, "//e/text()")
        @test length(results) == 1
        @test value(results[1]) == "deep"
    end

    @testset "wildcard with predicate" begin
        doc2 = parse("""<r><a x="1"/><b x="2"/><c/></r>""", Node)
        results = xpath(doc2, "/r/*[@x]")
        @test length(results) == 2
    end

    @testset "// from non-document node" begin
        root = xpath(doc, "/root")[1]
        results = xpath(root, "//name")
        @test length(results) == 3
    end
end

#==============================================================================#
#                              LAZYNODE                                        #
#==============================================================================#
@testset "LazyNode" begin
    @testset "parse and nodetype" begin
        doc = parse("<root/>", LazyNode)
        @test nodetype(doc) == Document

        doc2 = parse(LazyNode, "<root/>")
        @test nodetype(doc2) == Document
    end

    @testset "read from IO" begin
        xml = """<?xml version="1.0"?><root>hello</root>"""
        doc = read(IOBuffer(xml), LazyNode)
        @test nodetype(doc) == Document
    end

    @testset "read from file" begin
        path = joinpath(@__DIR__, "data", "books.xml")
        isfile(path) || return
        doc = read(path, LazyNode)
        @test nodetype(doc) == Document
        @test length(children(doc)) > 0
    end

    @testset "Document children" begin
        xml = """<?xml version="1.0"?><root><child/></root>"""
        doc = parse(xml, LazyNode)
        ch = children(doc)
        @test length(ch) == 2
        @test nodetype(ch[1]) == Declaration
        @test nodetype(ch[2]) == Element
    end

    @testset "Document with all prolog node types" begin
        xml = """<?xml version="1.0"?><!DOCTYPE root SYSTEM "r.dtd"><!-- comment --><?pi data?><root/>"""
        doc = parse(xml, LazyNode)
        ch = children(doc)
        types = map(nodetype, ch)
        @test Declaration in types
        @test DTD in types
        @test Comment in types
        @test ProcessingInstruction in types
        @test Element in types
    end

    @testset "Element tag" begin
        doc = parse("<root/>", LazyNode)
        @test tag(doc[1]) == "root"
    end

    @testset "tag returns nothing for non-element/PI" begin
        doc = parse("<root>text</root>", LazyNode)
        text_node = children(doc[1])[1]
        @test nodetype(text_node) == Text
        @test tag(text_node) === nothing
    end

    @testset "Element attributes" begin
        doc = parse("""<root a="1" b="2"/>""", LazyNode)
        attrs = attributes(doc[1])
        @test attrs isa Attributes
        @test attrs["a"] == "1"
        @test attrs["b"] == "2"
    end

    @testset "Element with no attributes" begin
        doc = parse("<root/>", LazyNode)
        @test attributes(doc[1]) === nothing
    end

    @testset "attributes returns nothing for non-element" begin
        doc = parse("<root>text</root>", LazyNode)
        @test attributes(children(doc[1])[1]) === nothing
    end

    @testset "attributes unescape entity references" begin
        doc = parse("""<x a="a&amp;b"/>""", LazyNode)
        @test doc[1]["a"] == "a&b"
    end

    @testset "attribute-value normalization (XML 1.0 §3.3.3)" begin
        # Literal white space (#x9 #xA #xD) in attribute values reads as spaces — the CRLF
        # pair as ONE space — while white space written as character references survives.
        # Normalization happens on the raw slice, before entity resolution, uniformly
        # across the four readers.
        function attr_by_reader(xml, name)
            n = only(elements(parse(xml, Node)))[name]
            l = only(elements(parse(xml, LazyNode)))[name]
            f = only(elements(parse(xml, FlatNode)))[name]
            cur = Cursor(xml)
            c = nothing
            while next!(cur) !== nothing
                nodetype(cur) === Element && (c = attributes(cur)[name])
            end
            (n, l, f, c)
        end

        @testset "literal whitespace becomes spaces" begin
            vals = attr_by_reader("<a note=\"L1\nL2\tT\rR\"/>", "note")
            @test all(==("L1 L2 T R"), vals)
        end

        @testset "character references survive" begin
            vals = attr_by_reader("<a note=\"L1&#10;L2&#9;T&#13;R\"/>", "note")
            @test all(==("L1\nL2\tT\rR"), vals)
        end

        @testset "the CRLF pair collapses to one space" begin
            vals = attr_by_reader("<a note=\"L1\r\nL2\"/>", "note")
            @test all(==("L1 L2"), vals)
            @test only(elements(parse("<a n=\"x\r\n\r\ny\"/>", Node)))["n"] == "x  y"
            @test only(elements(parse("<a n=\"x\n\r\ny\"/>", Node)))["n"] == "x  y"
        end

        @testset "single-attribute fast paths" begin
            lz = only(elements(parse("<a note=\"p\tq\"/>", LazyNode)))
            @test get(lz, "note", "") == "p q"
            cur = Cursor("<a note=\"p\tq\"/>")
            while next!(cur) !== nothing
                nodetype(cur) === Element && @test get(cur, "note", "") == "p q"
            end
        end

        @testset "eachattribute path" begin
            el = only(elements(parse("<a x=\"1\n2\" y=\"&#10;\"/>", LazyNode)))
            @test collect(XML.eachattribute(el)) == ["x" => "1 2", "y" => "\n"]
        end

        @testset "W3C xmltest 043: attribute wrapped across a CRLF line" begin
            # byte-for-byte the suite's xmltest/valid/sa/043.xml (CRLF line ends); its
            # canonical reference out/043.xml expects a1="foo bar" — one space
            xml043 = "<!DOCTYPE doc [\r\n<!ATTLIST doc a1 CDATA #IMPLIED>\r\n<!ELEMENT doc (#PCDATA)>\r\n]>\r\n<doc a1=\"foo\r\nbar\"></doc>\r\n"
            @test only(elements(parse(xml043, Node)))["a1"] == "foo bar"
        end

        @testset "write escapes attribute whitespace as character references" begin
            el = XML.Element("a"; note = "L1\nL2\tT\rR")
            out = XML.write(el)
            @test occursin("note=\"L1&#10;L2&#9;T&#13;R\"", out)
            back = only(elements(parse(out, Node)))
            @test back["note"] == "L1\nL2\tT\rR"         # the value round-trips exactly
        end
    end

    @testset "Declaration attributes" begin
        doc = parse("""<?xml version="1.0" encoding="UTF-8"?><root/>""", LazyNode)
        decl = doc[1]
        @test nodetype(decl) == Declaration
        attrs = attributes(decl)
        @test attrs["version"] == "1.0"
        @test attrs["encoding"] == "UTF-8"
    end

    @testset "get with default" begin
        doc = parse("""<x a="1"/>""", LazyNode)
        el = doc[1]
        @test get(el, "a", "nope") == "1"
        @test get(el, "b", "nope") == "nope"
    end

    @testset "get on non-element returns default" begin
        doc = parse("<root>text</root>", LazyNode)
        text_node = children(doc[1])[1]
        @test get(text_node, "a", "default") == "default"
    end

    @testset "getindex with string key" begin
        doc = parse("""<x a="1"/>""", LazyNode)
        @test doc[1]["a"] == "1"
        @test_throws KeyError doc[1]["nonexistent"]
    end

    @testset "haskey" begin
        doc = parse("""<x a="1"/>""", LazyNode)
        @test haskey(doc[1], "a") == true
        @test haskey(doc[1], "b") == false
    end

    @testset "keys" begin
        doc = parse("""<x a="1" b="2"/>""", LazyNode)
        @test keys(doc[1]) == ["a", "b"]
    end

    @testset "keys on element with no attributes" begin
        doc = parse("<x/>", LazyNode)
        @test isempty(keys(doc[1]))
    end

    @testset "keys on non-element" begin
        doc = parse("<root>text</root>", LazyNode)
        @test keys(children(doc[1])[1]) == ()
    end

    @testset "Text value" begin
        doc = parse("<root>hello</root>", LazyNode)
        ch = children(doc[1])
        @test nodetype(ch[1]) == Text
        @test value(ch[1]) == "hello"
    end

    @testset "Text value unescapes entities" begin
        doc = parse("<root>&amp; &lt; &gt;</root>", LazyNode)
        @test value(children(doc[1])[1]) == "& < >"
    end

    @testset "has_entities short-circuit (zero-copy, correctness)" begin
        # Entity-free Text: returns the raw SubString view, no allocation.
        doc = parse("<root>plain text no entities</root>", LazyNode)
        v = value(children(doc[1])[1])
        @test v isa SubString{String}
        @test v == "plain text no entities"
        @test (@allocated value(children(doc[1])[1])) ≥ 0  # smoke

        # Entity-bearing Text: still decodes byte-for-byte like unescape.
        d2 = parse("<root>a &amp; b &#x41; &#65; &lt;</root>", LazyNode)
        tv = value(children(d2[1])[1])
        @test tv == unescape(SubString("a &amp; b &#x41; &#65; &lt;"))
        @test tv == "a & b A A <"

        # Entity-free attribute: zero-copy SubString view.
        d3 = parse("""<c r="A1" s="3" t="n"/>""", LazyNode)
        c = d3[1]
        @test get(c, "r", nothing) isa SubString{String}
        @test get(c, "r", nothing) == "A1"
        a = attributes(c)
        @test a["s"] == "3"
        @test a["s"] isa SubString{String}
        pairs_collected = collect(eachattribute(c))
        @test pairs_collected == ["r" => "A1", "s" => "3", "t" => "n"]
        @test all(p -> last(p) isa SubString{String}, pairs_collected)

        # Entity-bearing attribute: decoded.
        d4 = parse("""<x a="x &amp; y" b="plain"/>""", LazyNode)
        x = d4[1]
        @test x["a"] == "x & y"
        @test get(x, "b", nothing) == "plain"
        @test get(x, "b", nothing) isa SubString{String}
        @test attributes(x)["a"] == "x & y"
        @test Dict(eachattribute(x)) == Dict("a" => "x & y", "b" => "plain")

        # CDATA carries markup characters verbatim — never entity-decoded.
        d5 = parse("<root><![CDATA[a & b < c &amp; d]]></root>", LazyNode)
        cd = children(d5[1])[1]
        @test nodetype(cd) == CData
        @test value(cd) == "a & b < c &amp; d"

        # is_simple_value: entity-free returns view, entity-bearing decodes.
        s1 = parse("<t>simple</t>", LazyNode)[1]
        @test XML.is_simple_value(s1) == "simple"
        @test XML.is_simple_value(s1) isa SubString{String}
        s2 = parse("<t>a &amp; b</t>", LazyNode)[1]
        @test XML.is_simple_value(s2) == "a & b"
    end

    @testset "Comment value" begin
        doc = parse("<root><!-- a comment --></root>", LazyNode)
        c = children(doc[1])[1]
        @test nodetype(c) == Comment
        @test value(c) == " a comment "
    end

    @testset "CData value" begin
        doc = parse("<root><![CDATA[raw <data>]]></root>", LazyNode)
        cd = children(doc[1])[1]
        @test nodetype(cd) == CData
        @test value(cd) == "raw <data>"
    end

    @testset "DTD value" begin
        doc = parse("""<!DOCTYPE greeting SYSTEM "hello.dtd"><greeting/>""", LazyNode)
        dtd = doc[1]
        @test nodetype(dtd) == DTD
        @test contains(value(dtd), "greeting")
    end

    @testset "ProcessingInstruction tag and value" begin
        doc = parse("<?mypi some data?><root/>", LazyNode)
        pi = doc[1]
        @test nodetype(pi) == ProcessingInstruction
        @test tag(pi) == "mypi"
        @test value(pi) == "some data"
    end

    @testset "ProcessingInstruction with no content" begin
        doc = parse("<?target?><root/>", LazyNode)
        pi = doc[1]
        @test tag(pi) == "target"
        @test value(pi) === nothing
    end

    @testset "value returns nothing for Element/Document" begin
        doc = parse("<root/>", LazyNode)
        @test value(doc) === nothing
        @test value(doc[1]) === nothing
    end

    @testset "Element children" begin
        doc = parse("<root><a/><b/><c/></root>", LazyNode)
        root = doc[1]
        @test length(children(root)) == 3
        @test tag(children(root)[1]) == "a"
        @test tag(children(root)[2]) == "b"
        @test tag(children(root)[3]) == "c"
    end

    @testset "self-closing element has no children" begin
        doc = parse("<root><br/></root>", LazyNode)
        br = children(doc[1])[1]
        @test isempty(children(br))
    end

    @testset "non-element children returns empty tuple" begin
        doc = parse("<root>text</root>", LazyNode)
        text_node = children(doc[1])[1]
        @test children(text_node) == ()
    end

    @testset "nested elements" begin
        doc = parse("<a><b><c>deep</c></b></a>", LazyNode)
        @test tag(doc[1]) == "a"
        @test tag(doc[1][1]) == "b"
        @test tag(doc[1][1][1]) == "c"
        @test simple_value(doc[1][1][1]) == "deep"
    end

    @testset "mixed content children" begin
        xml = "<root>text<!-- comment --><![CDATA[cdata]]><?pi data?><child/></root>"
        doc = parse(xml, LazyNode)
        ch = children(doc[1])
        types = map(nodetype, ch)
        @test Text in types
        @test Comment in types
        @test CData in types
        @test ProcessingInstruction in types
        @test Element in types
    end

    @testset "integer indexing" begin
        doc = parse("<root><a/><b/><c/></root>", LazyNode)
        @test tag(doc[1][1]) == "a"
        @test tag(doc[1][2]) == "b"
        @test tag(doc[1][3]) == "c"
    end

    @testset "colon indexing" begin
        doc = parse("<root><a/><b/></root>", LazyNode)
        all = doc[1][:]
        @test length(all) == 2
    end

    @testset "lastindex" begin
        doc = parse("<root><a/><b/><c/></root>", LazyNode)
        @test tag(doc[1][end]) == "c"
    end

    @testset "only" begin
        doc = parse("<root><only/></root>", LazyNode)
        @test tag(only(doc[1])) == "only"
    end

    @testset "length" begin
        doc = parse("<root><a/><b/><c/></root>", LazyNode)
        @test length(doc[1]) == 3
    end

    @testset "is_simple" begin
        doc = parse("<root><simple>text</simple><complex><child/></complex></root>", LazyNode)
        simple = children(doc[1])[1]
        complex = children(doc[1])[2]
        @test is_simple(simple)
        @test !is_simple(complex)
    end

    @testset "is_simple with attributes" begin
        doc = parse("""<root><x a="1">text</x></root>""", LazyNode)
        @test !is_simple(children(doc[1])[1])
    end

    @testset "is_simple with CData child" begin
        doc = parse("<root><x><![CDATA[data]]></x></root>", LazyNode)
        @test is_simple(children(doc[1])[1])
    end

    @testset "is_simple returns false for non-element" begin
        doc = parse("<root>text</root>", LazyNode)
        @test !is_simple(children(doc[1])[1])
    end

    @testset "simple_value" begin
        doc = parse("<root><x>hello</x></root>", LazyNode)
        @test simple_value(children(doc[1])[1]) == "hello"
    end

    @testset "simple_value errors on non-simple" begin
        doc = parse("<root><x><y/></x></root>", LazyNode)
        @test_throws ErrorException simple_value(children(doc[1])[1])
    end

    @testset "simple_value errors on non-element" begin
        doc = parse("<root>text</root>", LazyNode)
        @test_throws ErrorException simple_value(children(doc[1])[1])
    end

    @testset "show Document" begin
        doc = parse("<root><a/></root>", LazyNode)
        s = sprint(show, doc)
        @test contains(s, "Lazy")
        @test contains(s, "Document")
        @test contains(s, "1 child")
    end

    @testset "show Document multiple children" begin
        doc = parse("<!-- c --><root/>", LazyNode)
        s = sprint(show, doc)
        @test contains(s, "2 children")
    end

    @testset "show Element" begin
        doc = parse("""<root a="1"/>""", LazyNode)
        s = sprint(show, doc[1])
        @test contains(s, "Lazy Element")
        @test contains(s, "<root")
    end

    @testset "show Text" begin
        doc = parse("<root>hello</root>", LazyNode)
        s = sprint(show, children(doc[1])[1])
        @test contains(s, "Lazy Text")
        @test contains(s, "hello")
    end

    @testset "show Comment" begin
        doc = parse("<root><!-- test --></root>", LazyNode)
        s = sprint(show, children(doc[1])[1])
        @test contains(s, "Lazy Comment")
        @test contains(s, "<!--")
    end

    @testset "show CData" begin
        doc = parse("<root><![CDATA[data]]></root>", LazyNode)
        s = sprint(show, children(doc[1])[1])
        @test contains(s, "Lazy CData")
        @test contains(s, "<![CDATA[")
    end

    @testset "show DTD" begin
        doc = parse("<!DOCTYPE html><html/>", LazyNode)
        s = sprint(show, doc[1])
        @test contains(s, "Lazy DTD")
        @test contains(s, "<!DOCTYPE")
    end

    @testset "show Declaration" begin
        doc = parse("""<?xml version="1.0"?><root/>""", LazyNode)
        s = sprint(show, doc[1])
        @test contains(s, "Lazy Declaration")
        @test contains(s, "<?xml")
    end

    @testset "show ProcessingInstruction" begin
        doc = parse("<?target data?><root/>", LazyNode)
        s = sprint(show, doc[1])
        @test contains(s, "Lazy ProcessingInstruction")
        @test contains(s, "<?target")
    end

    @testset "show ProcessingInstruction without content" begin
        doc = parse("<?target?><root/>", LazyNode)
        s = sprint(show, doc[1])
        @test contains(s, "<?target?>")
    end

    @testset "LazyNode agrees with Node on books.xml" begin
        path = joinpath(@__DIR__, "data", "books.xml")
        isfile(path) || return

        eager = read(path, Node)
        lazy = read(path, LazyNode)

        # Same top-level structure
        eager_ch = children(eager)
        lazy_ch = children(lazy)
        @test length(eager_ch) == length(lazy_ch)
        @test map(nodetype, eager_ch) == map(nodetype, lazy_ch)

        # Find root element in both
        eager_root = first(filter(x -> nodetype(x) == Element, eager_ch))
        lazy_root = first(filter(x -> nodetype(x) == Element, lazy_ch))
        @test tag(eager_root) == tag(lazy_root)

        # Same number of book elements
        eager_books = filter(x -> nodetype(x) == Element, children(eager_root))
        lazy_books = filter(x -> nodetype(x) == Element, children(lazy_root))
        @test length(eager_books) == length(lazy_books)

        # First book has same attributes and child values
        eb1 = eager_books[1]
        lb1 = lazy_books[1]
        @test eb1["id"] == lb1["id"]

        eager_author = first(filter(x -> nodetype(x) == Element && tag(x) == "author", children(eb1)))
        lazy_author = first(filter(x -> nodetype(x) == Element && tag(x) == "author", children(lb1)))
        @test simple_value(eager_author) == simple_value(lazy_author)
    end

    @testset "complex document" begin
        xml = """<?xml version="1.0"?>
<!DOCTYPE root SYSTEM "root.dtd">
<!-- comment -->
<?pi data?>
<root attr="val">
    text content
    <child>inner</child>
    <![CDATA[cdata content]]>
    <!-- inner comment -->
    <?inner-pi inner data?>
    <empty/>
</root>"""
        doc = parse(xml, LazyNode)
        @test nodetype(doc) == Document

        typed = filter(x -> nodetype(x) != Text, children(doc))
        @test nodetype(typed[1]) == Declaration
        @test nodetype(typed[2]) == DTD
        @test nodetype(typed[3]) == Comment
        @test nodetype(typed[4]) == ProcessingInstruction
        @test nodetype(typed[5]) == Element

        root = typed[5]
        @test tag(root) == "root"
        @test root["attr"] == "val"

        inner = children(root)
        inner_types = map(nodetype, inner)
        @test Text in inner_types
        @test Element in inner_types
        @test CData in inner_types
        @test Comment in inner_types
        @test ProcessingInstruction in inner_types

        child_els = filter(x -> nodetype(x) == Element, inner)
        @test length(child_els) == 2
        @test tag(child_els[1]) == "child"
        @test simple_value(child_els[1]) == "inner"
        @test tag(child_els[2]) == "empty"
    end

    @testset "sourcetext" begin
        @testset "self-closing element" begin
            doc = parse("<root/>", LazyNode)
            @test sourcetext(doc[1]) == "<root/>"
        end

        @testset "element with attributes" begin
            xml = """<root attr="val"/>"""
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == xml
        end

        @testset "element with children" begin
            xml = "<root><child>text</child></root>"
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == xml
            root = doc[1]
            child = first(c for c in children(root) if nodetype(c) == Element)
            @test sourcetext(child) == "<child>text</child>"
        end

        @testset "nested elements" begin
            xml = "<a><b><c>deep</c></b></a>"
            doc = parse(xml, LazyNode)
            a = doc[1]
            @test sourcetext(a) == xml
            b = first(c for c in children(a) if nodetype(c) == Element)
            @test sourcetext(b) == "<b><c>deep</c></b>"
        end

        @testset "comment" begin
            xml = "<!-- hello --><root/>"
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == "<!-- hello -->"
        end

        @testset "cdata" begin
            xml = "<root><![CDATA[some <data>]]></root>"
            doc = parse(xml, LazyNode)
            cdata = first(c for c in children(doc[1]) if nodetype(c) == CData)
            @test sourcetext(cdata) == "<![CDATA[some <data>]]>"
        end

        @testset "processing instruction" begin
            xml = "<?target data?><root/>"
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == "<?target data?>"
        end

        @testset "declaration" begin
            xml = """<?xml version="1.0"?><root/>"""
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == """<?xml version="1.0"?>"""
        end

        @testset "DTD" begin
            xml = """<!DOCTYPE html SYSTEM "html.dtd"><html/>"""
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == """<!DOCTYPE html SYSTEM "html.dtd">"""
        end

        @testset "text node" begin
            doc = parse("<root>hello world</root>", LazyNode)
            txt = first(c for c in children(doc[1]) if nodetype(c) == Text)
            @test sourcetext(txt) == "hello world"
        end

        @testset "document" begin
            xml = "<root>hello</root>"
            doc = parse(xml, LazyNode)
            @test sourcetext(doc) == xml
        end

        @testset "mixed content" begin
            xml = "<p>Hello <b>world</b> and <i>more</i></p>"
            doc = parse(xml, LazyNode)
            @test sourcetext(doc[1]) == xml
        end
    end

    @testset "sourcespan" begin
        # sourcetext(n) == SubString(source, sourcespan(n)) on every node — valid
        # character indices, multibyte at both boundaries.
        xml = "<r>é<a x=\"1\">héé</a>œ<b/><!-- ç --></r>"
        doc = parse(xml, LazyNode)
        function check_spans(n)
            span = sourcespan(n)
            @test span isa UnitRange{Int}
            @test SubString(xml, span) == sourcetext(n)
            @test xml[span] == sourcetext(n)
            for c in XML.eachchildnode(n)
                check_spans(c)
            end
        end
        check_spans(doc)

        @testset "document spans the whole source" begin
            @test sourcespan(doc) == firstindex(xml):lastindex(xml)
        end

        @testset "splice idiom from the docstring" begin
            # excise <a …>…</a> — preceded by "é", followed by "œ": the documented
            # prevind/nextind splice must survive both multibyte boundaries
            a = first(c for c in children(doc[1]) if nodetype(c) == Element)
            span = sourcespan(a)
            stripped = xml[1:prevind(xml, first(span))] * "<c/>" * xml[nextind(xml, last(span)):end]
            @test stripped == "<r>é<c/>œ<b/><!-- ç --></r>"
            @test splicetext(a, "<c/>") == stripped              # the packaged form
            @test splicetext(a) == "<r>éœ<b/><!-- ç --></r>"     # default = pure excision
        end

        @testset "text node ending on a multibyte character" begin
            s = "<x>héé</x>"
            txt = first(c for c in children(parse(s, LazyNode)[1]) if nodetype(c) == Text)
            @test s[sourcespan(txt)] == "héé"
        end
    end

    @testset "write(::LazyNode)" begin
        @testset "write returns String" begin
            xml = "<root><child>text</child></root>"
            doc = parse(xml, LazyNode)
            @test XML.write(doc[1]) == xml
            @test XML.write(doc[1]) isa String
        end

        @testset "write to IO" begin
            xml = "<root><child>text</child></root>"
            doc = parse(xml, LazyNode)
            io = IOBuffer()
            XML.write(io, doc[1])
            @test String(take!(io)) == xml
        end
    end

    @testset "eachchildnode" begin
        @testset "matches children for element" begin
            xml = "<root><a/><b>text</b><c><d/></c></root>"
            doc = parse(xml, LazyNode)
            root = doc[1]
            eager = children(root)
            lazy = collect(eachchildnode(root))
            @test length(eager) == length(lazy)
            @test map(nodetype, eager) == map(nodetype, lazy)
            @test map(tag, eager) == map(tag, lazy)
        end

        @testset "self-closing element has no children" begin
            doc = parse("<root/>", LazyNode)
            @test isempty(collect(eachchildnode(doc[1])))
        end

        @testset "document children" begin
            xml = """<?xml version="1.0"?><!-- comment --><root/>"""
            doc = parse(xml, LazyNode)
            eager = children(doc)
            lazy = collect(eachchildnode(doc))
            @test length(eager) == length(lazy)
            @test map(nodetype, eager) == map(nodetype, lazy)
        end

        @testset "mixed content types" begin
            xml = """<root>text<!-- comment --><![CDATA[cdata]]><?pi data?><child/></root>"""
            doc = parse(xml, LazyNode)
            root = doc[1]
            types = [nodetype(c) for c in eachchildnode(root)]
            @test Text in types
            @test Comment in types
            @test CData in types
            @test ProcessingInstruction in types
            @test Element in types
        end

        @testset "sourcetext works on eachchildnode results" begin
            xml = "<sst><si><t>hello</t></si><si><t>world</t></si></sst>"
            doc = parse(xml, LazyNode)
            root = doc[1]
            results = [XML.write(c) for c in eachchildnode(root)]
            @test results == ["<si><t>hello</t></si>", "<si><t>world</t></si>"]
        end

        @testset "non-element/document returns empty" begin
            xml = "<!-- comment --><root/>"
            doc = parse(xml, LazyNode)
            comment = doc[1]
            @test nodetype(comment) == Comment
            @test isempty(collect(eachchildnode(comment)))
        end
    end
end

# Each included suite is wrapped in a @testset so a load-time error in one file can't skip the rest.
@testset "test_abstracttrees_ext" begin include("test_abstracttrees_ext.jl") end
@testset "test_pugixml" begin include("test_pugixml.jl") end
@testset "test_libexpat" begin include("test_libexpat.jl") end
@testset "test_libxml2_testcases" begin include("test_libxml2_testcases.jl") end
@testset "test_w3c" begin include("test_w3c.jl") end
@testset "test_tokenizer" begin include("test_tokenizer.jl") end
@testset "test_cursor" begin include("test_cursor.jl") end
@testset "test_flatnode" begin include("test_flatnode.jl") end
@testset "test_node_identity" begin include("test_node_identity.jl") end

Test.pop_testset()
Test.finish(_ROOT_TS)   # prints the aggregated summary and throws (exit 1) if anything failed
