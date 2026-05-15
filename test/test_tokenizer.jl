using Test, XML

using XML.XMLTokenizer

# Convenience: collect token kinds from a string
kinds(xml) = [t.kind for t in tokenize(xml)]
raws(xml)  = [String(t.raw) for t in tokenize(xml)]

@testset "XMLTokenizer" begin

#-----------------------------------------------------------------------# Basic text
@testset "plain text" begin
    toks = collect(tokenize("hello world"))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.TEXT
    @test toks[1].raw == "hello world"
end

@testset "empty string" begin
    @test isempty(collect(tokenize("")))
end

#-----------------------------------------------------------------------# Open tags
@testset "open tag without attributes" begin
    @test kinds("<div>") == [TokenKinds.OPEN_TAG, TokenKinds.TAG_CLOSE]
    @test raws("<div>") == ["<div", ">"]
end

@testset "open tag with attributes" begin
    xml = """<a href="url" class='main'>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.OPEN_TAG,
        TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE,
        TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE,
        TokenKinds.TAG_CLOSE,
    ]
    @test tag_name(toks[1]) == "a"
    @test toks[2].raw == "href"
    @test attr_value(toks[3]) == "url"
    @test toks[4].raw == "class"
    @test attr_value(toks[5]) == "main"
end

@testset "whitespace around =" begin
    xml = """<x a = "1" >"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.OPEN_TAG, TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE, TokenKinds.TAG_CLOSE,
    ]
    @test attr_value(toks[3]) == "1"
end

#-----------------------------------------------------------------------# Self-closing tags
@testset "self-closing tag" begin
    @test kinds("<br/>") == [TokenKinds.OPEN_TAG, TokenKinds.SELF_CLOSE]
    @test raws("<br/>") == ["<br", "/>"]
end

@testset "self-closing tag with attributes" begin
    xml = """<img src="a.png" />"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.OPEN_TAG, TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE, TokenKinds.SELF_CLOSE,
    ]
    @test tag_name(toks[1]) == "img"
    @test attr_value(toks[3]) == "a.png"
end

#-----------------------------------------------------------------------# Close tags
@testset "close tag" begin
    toks = collect(tokenize("</div>"))
    @test [t.kind for t in toks] == [TokenKinds.CLOSE_TAG, TokenKinds.TAG_CLOSE]
    @test tag_name(toks[1]) == "div"
    @test toks[2].raw == ">"
end

@testset "close tag with whitespace" begin
    toks = collect(tokenize("</div  >"))
    @test [t.kind for t in toks] == [TokenKinds.CLOSE_TAG, TokenKinds.TAG_CLOSE]
    @test tag_name(toks[1]) == "div"
end

#-----------------------------------------------------------------------# Open + close round-trip
@testset "element with text" begin
    xml = "<p>hello</p>"
    @test kinds(xml) == [
        TokenKinds.OPEN_TAG, TokenKinds.TAG_CLOSE,
        TokenKinds.TEXT,
        TokenKinds.CLOSE_TAG, TokenKinds.TAG_CLOSE,
    ]
    toks = collect(tokenize(xml))
    @test tag_name(toks[1]) == "p"
    @test toks[3].raw == "hello"
    @test tag_name(toks[4]) == "p"
end

#-----------------------------------------------------------------------# Namespaced tags
@testset "namespaced tag" begin
    xml = """<ns:el xmlns:ns="http://example.com">"""
    toks = collect(tokenize(xml))
    @test tag_name(toks[1]) == "ns:el"
    @test toks[2].raw == "xmlns:ns"
end

#-----------------------------------------------------------------------# Comments
@testset "comment" begin
    xml = "<!-- hello -->"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.COMMENT_OPEN, TokenKinds.COMMENT_CONTENT, TokenKinds.COMMENT_CLOSE]
    @test toks[1].raw == "<!--"
    @test toks[2].raw == " hello "
    @test toks[3].raw == "-->"
end

@testset "empty comment" begin
    toks = collect(tokenize("<!---->"))
    @test [t.kind for t in toks] == [TokenKinds.COMMENT_OPEN, TokenKinds.COMMENT_CONTENT, TokenKinds.COMMENT_CLOSE]
    @test toks[2].raw == ""
end

@testset "comment with markup-like content" begin
    toks = collect(tokenize("<!-- <b>not</b> a tag -->"))
    @test toks[2].raw == " <b>not</b> a tag "
end

#-----------------------------------------------------------------------# CDATA
@testset "CDATA" begin
    xml = "<![CDATA[raw & <text>]]>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.CDATA_OPEN, TokenKinds.CDATA_CONTENT, TokenKinds.CDATA_CLOSE]
    @test toks[1].raw == "<![CDATA["
    @test toks[2].raw == "raw & <text>"
    @test toks[3].raw == "]]>"
end

@testset "empty CDATA" begin
    toks = collect(tokenize("<![CDATA[]]>"))
    @test [t.kind for t in toks] == [TokenKinds.CDATA_OPEN, TokenKinds.CDATA_CONTENT, TokenKinds.CDATA_CLOSE]
    @test toks[2].raw == ""
end

#-----------------------------------------------------------------------# Processing instructions
@testset "processing instruction" begin
    xml = """<?style type="text/css"?>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.PI_OPEN, TokenKinds.PI_CONTENT, TokenKinds.PI_CLOSE]
    @test toks[1].raw == "<?style"
    @test pi_target(toks[1]) == "style"
    @test toks[2].raw == """ type="text/css\""""
    @test toks[3].raw == "?>"
end

@testset "PI with no content" begin
    toks = collect(tokenize("<?target?>"))
    @test [t.kind for t in toks] == [TokenKinds.PI_OPEN, TokenKinds.PI_CONTENT, TokenKinds.PI_CLOSE]
    @test pi_target(toks[1]) == "target"
    @test toks[2].raw == ""
end

#-----------------------------------------------------------------------# XML declaration
@testset "XML declaration" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.XML_DECL_OPEN,
        TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE,
        TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE,
        TokenKinds.XML_DECL_CLOSE,
    ]
    @test pi_target(toks[1]) == "xml"
    @test toks[1].raw == "<?xml"
    @test toks[2].raw == "version"
    @test attr_value(toks[3]) == "1.0"
    @test toks[4].raw == "encoding"
    @test attr_value(toks[5]) == "UTF-8"
    @test toks[6].raw == "?>"
end

@testset "XML declaration with single quotes" begin
    xml = "<?xml version='1.0'?>"
    toks = collect(tokenize(xml))
    @test toks[3].raw == "'1.0'"
    @test attr_value(toks[3]) == "1.0"
end

#-----------------------------------------------------------------------# DOCTYPE
@testset "DOCTYPE simple" begin
    xml = """<!DOCTYPE note SYSTEM "note.dtd">"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test toks[1].raw == "<!DOCTYPE"
    @test toks[2].raw == """ note SYSTEM "note.dtd\""""
    @test toks[3].raw == ">"
end

@testset "DOCTYPE with internal subset" begin
    xml = """<!DOCTYPE note [<!ELEMENT note (#PCDATA)>]>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test toks[2].raw == " note [<!ELEMENT note (#PCDATA)>]"
end

@testset "DOCTYPE with quoted > in internal subset" begin
    xml = """<!DOCTYPE note [<!ATTLIST x y CDATA "a>b">]>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test occursin("a>b", toks[2].raw)
end

#-----------------------------------------------------------------------# Full document
@testset "full document" begin
    xml = """<?xml version="1.0"?>
<!DOCTYPE root SYSTEM "root.dtd">
<root>
  <child id="1">text</child>
  <empty/>
  <!-- comment -->
  <![CDATA[data]]>
  <?pi content?>
</root>"""
    toks = collect(tokenize(xml))
    tok_kinds = [t.kind for t in toks]

    # XML declaration
    @test tok_kinds[1] == TokenKinds.XML_DECL_OPEN
    # DOCTYPE present
    @test TokenKinds.DOCTYPE_OPEN in tok_kinds
    # All open tags have matching closes
    open_names  = [tag_name(t) for t in toks if t.kind == TokenKinds.OPEN_TAG]
    close_names = [tag_name(t) for t in toks if t.kind == TokenKinds.CLOSE_TAG]
    @test open_names == ["root", "child", "empty"]
    @test close_names == ["child", "root"]
    # CDATA is present
    cdata_content = [t.raw for t in toks if t.kind == TokenKinds.CDATA_CONTENT]
    @test cdata_content == ["data"]
    # Comment is present
    comment_content = [t.raw for t in toks if t.kind == TokenKinds.COMMENT_CONTENT]
    @test comment_content == [" comment "]
    # PI is present
    pi_opens = [t for t in toks if t.kind == TokenKinds.PI_OPEN]
    @test length(pi_opens) == 1
    @test pi_target(pi_opens[1]) == "pi"
end

#-----------------------------------------------------------------------# Raw round-trip
@testset "concatenated raw reproduces input" begin
    # Round-trip works for inputs where no whitespace/= is consumed between tokens.
    # Whitespace around `=` in attributes is consumed and not part of any token.
    for xml in [
        """<!-- comment --><a/>""",
        """<![CDATA[hello]]>""",
        """<?pi data?>""",
        """<!DOCTYPE x [<!ELEMENT x (#PCDATA)>]><x/>""",
        """<p>text</p>""",
    ]
        reconstructed = join(t.raw for t in tokenize(xml))
        @test reconstructed == xml
    end
end

@testset "attribute whitespace is not preserved" begin
    # Whitespace around `=` and between attrs is consumed, not emitted as tokens.
    xml = """<a b = "c"  d='e' />"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.OPEN_TAG, TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE,
        TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE, TokenKinds.SELF_CLOSE,
    ]
end

#-----------------------------------------------------------------------# Iterator protocol
@testset "iterator protocol" begin
    t = tokenize("<a/>")
    @test Base.IteratorSize(typeof(t)) == Base.SizeUnknown()
    @test Base.eltype(typeof(t)) == Token
    toks = collect(t)
    @test length(toks) == 2
end

#-----------------------------------------------------------------------# Utility error handling
@testset "tag_name errors on wrong kind" begin
    tok = first(tokenize("hello"))
    @test_throws ArgumentError tag_name(tok)
end

@testset "attr_value errors on wrong kind" begin
    tok = first(tokenize("<a>"))
    @test_throws ArgumentError attr_value(tok)
end

@testset "pi_target errors on wrong kind" begin
    tok = first(tokenize("<a>"))
    @test_throws ArgumentError pi_target(tok)
end

#-----------------------------------------------------------------------# Error cases
@testset "error: unterminated comment" begin
    @test_throws ArgumentError collect(tokenize("<!-- no end"))
end

@testset "error: unterminated CDATA" begin
    @test_throws ArgumentError collect(tokenize("<![CDATA[no end"))
end

@testset "error: unterminated PI" begin
    @test_throws ArgumentError collect(tokenize("<?pi no end"))
end

@testset "unterminated open tag emits partial token" begin
    # Tokenizer emits what it can; the tag is never closed but no error since EOF is reached
    toks = collect(tokenize("<div"))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.OPEN_TAG
    @test tag_name(toks[1]) == "div"
end

@testset "unterminated close tag emits partial token" begin
    toks = collect(tokenize("</div"))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.CLOSE_TAG
    @test tag_name(toks[1]) == "div"
end

@testset "error: unterminated attribute value" begin
    @test_throws ArgumentError collect(tokenize("""<a b="no end"""))
end

@testset "error: unterminated DOCTYPE" begin
    @test_throws ArgumentError collect(tokenize("<!DOCTYPE x"))
end

@testset "error: lone <" begin
    @test_throws ArgumentError collect(tokenize("<"))
end

#-----------------------------------------------------------------------# Unicode content
@testset "unicode text content" begin
    xml = "<p>café ñ 日本語</p>"
    toks = collect(tokenize(xml))
    text_tok = toks[3]
    @test text_tok.kind == TokenKinds.TEXT
    @test text_tok.raw == "café ñ 日本語"
end

@testset "unicode in attribute value" begin
    xml = """<x a="über"/>"""
    toks = collect(tokenize(xml))
    @test attr_value(toks[3]) == "über"
end

@testset "unicode in comment" begin
    toks = collect(tokenize("<!-- héllo -->"))
    @test toks[2].raw == " héllo "
end

#-----------------------------------------------------------------------# Edge cases
@testset "adjacent tags" begin
    xml = "<a></a><b></b>"
    toks = collect(tokenize(xml))
    open_names  = [tag_name(t) for t in toks if t.kind == TokenKinds.OPEN_TAG]
    close_names = [tag_name(t) for t in toks if t.kind == TokenKinds.CLOSE_TAG]
    @test open_names == ["a", "b"]
    @test close_names == ["a", "b"]
    # No text tokens between them
    @test !any(t -> t.kind == TokenKinds.TEXT, toks)
end

@testset "text between adjacent tags" begin
    xml = "<a>x</a>y<b/>"
    texts = [t.raw for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test texts == ["x", "y"]
end

@testset "multiple attributes" begin
    xml = """<div a="1" b="2" c="3">"""
    names = [String(t.raw) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_NAME]
    vals  = [String(attr_value(t)) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_VALUE]
    @test names == ["a", "b", "c"]
    @test vals == ["1", "2", "3"]
end

@testset "attribute with > in value" begin
    xml = """<x a="1>2">"""
    toks = collect(tokenize(xml))
    @test attr_value(toks[3]) == "1>2"
    @test toks[end].kind == TokenKinds.TAG_CLOSE
end

@testset "attribute with single quotes" begin
    xml = "<x a='val'>"
    toks = collect(tokenize(xml))
    @test toks[3].raw == "'val'"
    @test attr_value(toks[3]) == "val"
end

@testset "mixed quote styles" begin
    xml = """<x a="1" b='2'>"""
    vals = [attr_value(t) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_VALUE]
    @test vals == ["1", "2"]
end

@testset "whitespace-only text" begin
    xml = "<a>  \n\t </a>"
    texts = [t for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test length(texts) == 1
    @test texts[1].raw == "  \n\t "
end

@testset "entities preserved verbatim" begin
    xml = "<p>&amp; &lt; &#x41;</p>"
    texts = [t.raw for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test texts == ["&amp; &lt; &#x41;"]
end

@testset "show method" begin
    tok = first(tokenize("hello"))
    buf = IOBuffer()
    show(buf, tok)
    s = String(take!(buf))
    @test occursin("TEXT", s)
    @test occursin("hello", s)
end

end # top-level testset
