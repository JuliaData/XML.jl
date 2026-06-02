using Test, XML

# Token-layer names are not exported by XMLTokenizer; import them explicitly so this file
# runs both standalone and when included from runtests.jl. `raw(token, data)` reconstructs
# a token's text view (Token stores only an offset+length byte range, not the SubString).
using XML.XMLTokenizer: tokenize, TokenKinds, Token, tag_name, attr_value, pi_target, raw

# Convenience: collect token kinds / texts from a string
kinds(xml) = [t.kind for t in tokenize(xml)]
raws(xml)  = [String(raw(t, xml)) for t in tokenize(xml)]

@testset "XMLTokenizer" begin

#-----------------------------------------------------------------------# Basic text
@testset "plain text" begin
    xml = "hello world"
    toks = collect(tokenize(xml))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.TEXT
    @test raw(toks[1], xml) == "hello world"
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
    @test tag_name(toks[1], xml) == "a"
    @test raw(toks[2], xml) == "href"
    @test attr_value(toks[3], xml) == "url"
    @test raw(toks[4], xml) == "class"
    @test attr_value(toks[5], xml) == "main"
end

@testset "whitespace around =" begin
    xml = """<x a = "1" >"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [
        TokenKinds.OPEN_TAG, TokenKinds.ATTR_NAME, TokenKinds.ATTR_VALUE, TokenKinds.TAG_CLOSE,
    ]
    @test attr_value(toks[3], xml) == "1"
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
    @test tag_name(toks[1], xml) == "img"
    @test attr_value(toks[3], xml) == "a.png"
end

#-----------------------------------------------------------------------# Close tags
@testset "close tag" begin
    xml = "</div>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.CLOSE_TAG, TokenKinds.TAG_CLOSE]
    @test tag_name(toks[1], xml) == "div"
    @test raw(toks[2], xml) == ">"
end

@testset "close tag with whitespace" begin
    xml = "</div  >"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.CLOSE_TAG, TokenKinds.TAG_CLOSE]
    @test tag_name(toks[1], xml) == "div"
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
    @test tag_name(toks[1], xml) == "p"
    @test raw(toks[3], xml) == "hello"
    @test tag_name(toks[4], xml) == "p"
end

#-----------------------------------------------------------------------# Namespaced tags
@testset "namespaced tag" begin
    xml = """<ns:el xmlns:ns="http://example.com">"""
    toks = collect(tokenize(xml))
    @test tag_name(toks[1], xml) == "ns:el"
    @test raw(toks[2], xml) == "xmlns:ns"
end

#-----------------------------------------------------------------------# Comments
@testset "comment" begin
    xml = "<!-- hello -->"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.COMMENT_OPEN, TokenKinds.COMMENT_CONTENT, TokenKinds.COMMENT_CLOSE]
    @test raw(toks[1], xml) == "<!--"
    @test raw(toks[2], xml) == " hello "
    @test raw(toks[3], xml) == "-->"
end

@testset "empty comment" begin
    xml = "<!---->"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.COMMENT_OPEN, TokenKinds.COMMENT_CONTENT, TokenKinds.COMMENT_CLOSE]
    @test raw(toks[2], xml) == ""
end

@testset "comment with markup-like content" begin
    xml = "<!-- <b>not</b> a tag -->"
    toks = collect(tokenize(xml))
    @test raw(toks[2], xml) == " <b>not</b> a tag "
end

#-----------------------------------------------------------------------# CDATA
@testset "CDATA" begin
    xml = "<![CDATA[raw & <text>]]>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.CDATA_OPEN, TokenKinds.CDATA_CONTENT, TokenKinds.CDATA_CLOSE]
    @test raw(toks[1], xml) == "<![CDATA["
    @test raw(toks[2], xml) == "raw & <text>"
    @test raw(toks[3], xml) == "]]>"
end

@testset "empty CDATA" begin
    xml = "<![CDATA[]]>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.CDATA_OPEN, TokenKinds.CDATA_CONTENT, TokenKinds.CDATA_CLOSE]
    @test raw(toks[2], xml) == ""
end

#-----------------------------------------------------------------------# Processing instructions
@testset "processing instruction" begin
    xml = """<?style type="text/css"?>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.PI_OPEN, TokenKinds.PI_CONTENT, TokenKinds.PI_CLOSE]
    @test raw(toks[1], xml) == "<?style"
    @test pi_target(toks[1], xml) == "style"
    @test raw(toks[2], xml) == """ type="text/css\""""
    @test raw(toks[3], xml) == "?>"
end

@testset "PI with no content" begin
    xml = "<?target?>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.PI_OPEN, TokenKinds.PI_CONTENT, TokenKinds.PI_CLOSE]
    @test pi_target(toks[1], xml) == "target"
    @test raw(toks[2], xml) == ""
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
    @test pi_target(toks[1], xml) == "xml"
    @test raw(toks[1], xml) == "<?xml"
    @test raw(toks[2], xml) == "version"
    @test attr_value(toks[3], xml) == "1.0"
    @test raw(toks[4], xml) == "encoding"
    @test attr_value(toks[5], xml) == "UTF-8"
    @test raw(toks[6], xml) == "?>"
end

@testset "XML declaration with single quotes" begin
    xml = "<?xml version='1.0'?>"
    toks = collect(tokenize(xml))
    @test raw(toks[3], xml) == "'1.0'"
    @test attr_value(toks[3], xml) == "1.0"
end

#-----------------------------------------------------------------------# DOCTYPE
@testset "DOCTYPE simple" begin
    xml = """<!DOCTYPE note SYSTEM "note.dtd">"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test raw(toks[1], xml) == "<!DOCTYPE"
    @test raw(toks[2], xml) == """ note SYSTEM "note.dtd\""""
    @test raw(toks[3], xml) == ">"
end

@testset "DOCTYPE with internal subset" begin
    xml = """<!DOCTYPE note [<!ELEMENT note (#PCDATA)>]>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test raw(toks[2], xml) == " note [<!ELEMENT note (#PCDATA)>]"
end

@testset "DOCTYPE with quoted > in internal subset" begin
    xml = """<!DOCTYPE note [<!ATTLIST x y CDATA "a>b">]>"""
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test occursin("a>b", raw(toks[2], xml))
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
    open_names  = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.OPEN_TAG]
    close_names = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.CLOSE_TAG]
    @test open_names == ["root", "child", "empty"]
    @test close_names == ["child", "root"]
    # CDATA is present
    cdata_content = [raw(t, xml) for t in toks if t.kind == TokenKinds.CDATA_CONTENT]
    @test cdata_content == ["data"]
    # Comment is present
    comment_content = [raw(t, xml) for t in toks if t.kind == TokenKinds.COMMENT_CONTENT]
    @test comment_content == [" comment "]
    # PI is present
    pi_opens = [t for t in toks if t.kind == TokenKinds.PI_OPEN]
    @test length(pi_opens) == 1
    @test pi_target(pi_opens[1], xml) == "pi"
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
        reconstructed = join(raw(t, xml) for t in tokenize(xml))
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
    @test_throws ArgumentError tag_name(tok, "hello")
end

@testset "attr_value errors on wrong kind" begin
    tok = first(tokenize("<a>"))
    @test_throws ArgumentError attr_value(tok, "<a>")
end

@testset "pi_target errors on wrong kind" begin
    tok = first(tokenize("<a>"))
    @test_throws ArgumentError pi_target(tok, "<a>")
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
    xml = "<div"
    toks = collect(tokenize(xml))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.OPEN_TAG
    @test tag_name(toks[1], xml) == "div"
end

@testset "unterminated close tag emits partial token" begin
    xml = "</div"
    toks = collect(tokenize(xml))
    @test length(toks) == 1
    @test toks[1].kind == TokenKinds.CLOSE_TAG
    @test tag_name(toks[1], xml) == "div"
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
    @test raw(text_tok, xml) == "café ñ 日本語"
end

@testset "unicode in attribute value" begin
    xml = """<x a="über"/>"""
    toks = collect(tokenize(xml))
    @test attr_value(toks[3], xml) == "über"
end

@testset "unicode in comment" begin
    xml = "<!-- héllo -->"
    toks = collect(tokenize(xml))
    @test raw(toks[2], xml) == " héllo "
end

#-----------------------------------------------------------------------# Edge cases
@testset "adjacent tags" begin
    xml = "<a></a><b></b>"
    toks = collect(tokenize(xml))
    open_names  = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.OPEN_TAG]
    close_names = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.CLOSE_TAG]
    @test open_names == ["a", "b"]
    @test close_names == ["a", "b"]
    # No text tokens between them
    @test !any(t -> t.kind == TokenKinds.TEXT, toks)
end

@testset "text between adjacent tags" begin
    xml = "<a>x</a>y<b/>"
    texts = [raw(t, xml) for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test texts == ["x", "y"]
end

@testset "multiple attributes" begin
    xml = """<div a="1" b="2" c="3">"""
    names = [String(raw(t, xml)) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_NAME]
    vals  = [String(attr_value(t, xml)) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_VALUE]
    @test names == ["a", "b", "c"]
    @test vals == ["1", "2", "3"]
end

@testset "attribute with > in value" begin
    xml = """<x a="1>2">"""
    toks = collect(tokenize(xml))
    @test attr_value(toks[3], xml) == "1>2"
    @test toks[end].kind == TokenKinds.TAG_CLOSE
end

@testset "attribute with single quotes" begin
    xml = "<x a='val'>"
    toks = collect(tokenize(xml))
    @test raw(toks[3], xml) == "'val'"
    @test attr_value(toks[3], xml) == "val"
end

@testset "mixed quote styles" begin
    xml = """<x a="1" b='2'>"""
    vals = [attr_value(t, xml) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_VALUE]
    @test vals == ["1", "2"]
end

@testset "whitespace-only text" begin
    xml = "<a>  \n\t </a>"
    texts = [t for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test length(texts) == 1
    @test raw(texts[1], xml) == "  \n\t "
end

@testset "entities preserved verbatim" begin
    xml = "<p>&amp; &lt; &#x41;</p>"
    texts = [raw(t, xml) for t in tokenize(xml) if t.kind == TokenKinds.TEXT]
    @test texts == ["&amp; &lt; &#x41;"]
end

@testset "show method" begin
    # Token no longer stores its text, so `show` prints kind + byte range, not the content.
    tok = first(tokenize("hello"))   # TEXT token spanning the whole input → "@0+5"
    buf = IOBuffer()
    show(buf, tok)
    s = String(take!(buf))
    @test occursin("TEXT", s)
    @test occursin("@0", s)
    @test occursin("+5", s)
end

end # top-level testset
