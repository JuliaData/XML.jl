using Test, XML, StringViews

# Token-layer names are not exported by XMLTokenizer; import them explicitly so this file
# runs both standalone and when included from runtests.jl. `raw(token, data)` reconstructs
# a token's text view (Token stores only an offset+length byte range, not the SubString).
using XML.XMLTokenizer: tokenize, TokenKinds, Token, tag_name, attr_value, pi_target, raw

# Convenience: collect token kinds / texts from a string
kinds(xml) = [t.kind for t in tokenize(xml)]
raws(xml)  = [String(raw(t, xml)) for t in tokenize(xml)]

# Multibyte torture document: 2-, 3-, and 4-byte UTF-8 in element names, attribute
# names/values, text, comment, CDATA, PI content and DOCTYPE body, plus an empty
# attribute value and entity-bearing text. Used by the span-equivalence sweeps below.
const MULTIBYTE_DOC = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE café [ <!-- déjà-vu --> ]>
<café idée="héllo wörld" 名前="日本語テキスト" emoji="🎈🎉" vide="">
  texte accentué été 🎯 &amp; fin
  <日本語 attr='単一引用符'>中身テキスト</日本語>
  <!-- commentaire évênement 🚀 -->
  <![CDATA[données brutes ]] presque-fin 💾]]>
  <?traitement instruction ciblée 🛰?>
  <vide/>
</café>
"""

# Reference reconstruction of a token's byte span [off+1, off+ncu] through Julia's
# checked, index-walking SubString path (empty spans reconstruct as ""). The accessors
# must agree with this on every token — proving the tokenizer's span arithmetic
# equivalent to checked string slicing, multibyte and empty spans included (issue #109).
checked_span(xml, off, ncu) =
    ncu == 0 ? SubString(xml, 1, 0) : SubString(xml, off + 1, prevind(xml, off + ncu + 1))

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

# Their text is free (§2.5, §2.6): a quote opens no string there, and a `]` closes nothing,
# so the internal subset ends at its own `]`.
@testset "DOCTYPE with $skipped in internal subset" for skipped in
        ("<!-- it's ]> -->", "<?pi it's?>", "<?pi \"?>", "<?pi ]> ?>")
    subset = " note [" * skipped * "<!ELEMENT note (#PCDATA)>]"
    xml = "<!DOCTYPE" * subset * "><note/>"
    toks = collect(tokenize(xml))
    @test [t.kind for t in toks[1:3]] == [TokenKinds.DOCTYPE_OPEN, TokenKinds.DOCTYPE_CONTENT, TokenKinds.DOCTYPE_CLOSE]
    @test raw(toks[2], xml) == subset
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

@testset "error: unterminated processing instruction in internal subset" begin
    # W3C ibm29n05: the only `?>` sits in an earlier literal, so none closes this one
    @test_throws ArgumentError collect(tokenize("<!DOCTYPE a [<!ENTITY % p \"x ?>\"><?music %p;\n]><a/>"))
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

@testset "multibyte element names" begin
    xml = "<café>x</café  ><日本語/><t🎈/>"
    toks = collect(tokenize(xml))
    opens  = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.OPEN_TAG]
    closes = [tag_name(t, xml) for t in toks if t.kind == TokenKinds.CLOSE_TAG]
    @test opens  == ["café", "日本語", "t🎈"]
    @test closes == ["café"]
end

@testset "multibyte attribute names and values" begin
    xml = """<x 名前="日本語テキスト" emoji="🎈🎉" idée='héllo wörld' vide=""/>"""
    names = [String(raw(t, xml)) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_NAME]
    vals  = [String(attr_value(t, xml)) for t in tokenize(xml) if t.kind == TokenKinds.ATTR_VALUE]
    @test names == ["名前", "emoji", "idée", "vide"]
    @test vals  == ["日本語テキスト", "🎈🎉", "héllo wörld", ""]
end

@testset "multibyte immediately before a delimiter" begin
    # The span's end boundary falls right after a 2-/3-/4-byte character in every reader
    # that stops on an ASCII sentinel ('<', quotes, '-->', ']]>', '?>', '>').
    xml = "<!--déjà-->"
    @test raw(collect(tokenize(xml))[2], xml) == "déjà"
    xml = "<![CDATA[日]]>"
    @test raw(collect(tokenize(xml))[2], xml) == "日"
    xml = "<?p ciblée 🛰?>"
    @test raw(collect(tokenize(xml))[2], xml) == " ciblée 🛰"
    xml = "<a>été</a>"
    @test raw(collect(tokenize(xml))[3], xml) == "été"
    xml = "<!DOCTYPE ré>"
    @test raw(collect(tokenize(xml))[2], xml) == " ré"
    xml = """<x a="é">"""
    @test attr_value(collect(tokenize(xml))[3], xml) == "é"
end

@testset "PI with multibyte target" begin
    xml = "<?ciblé données?>"
    toks = collect(tokenize(xml))
    @test pi_target(toks[1], xml) == "ciblé"
    @test raw(toks[2], xml) == " données"
end

#-----------------------------------------------------------------------# Span equivalence
@testset "accessors match checked span reconstruction" begin
    for xml in (
        MULTIBYTE_DOC,
        "<r a=\"1\"><c>text</c><!-- x --><![CDATA[d]]><?pi p?><e/></r>",
    )
        for t in tokenize(xml)
            r = raw(t, xml)
            @test r isa SubString{String}
            @test r == checked_span(xml, t.offset, t.ncodeunits)
            if t.kind == TokenKinds.OPEN_TAG
                @test tag_name(t, xml) == checked_span(xml, t.offset + 1, t.ncodeunits - 1)
            elseif t.kind == TokenKinds.CLOSE_TAG
                @test tag_name(t, xml) == checked_span(xml, t.offset + 2, t.ncodeunits - 2)
            elseif t.kind == TokenKinds.ATTR_VALUE
                @test attr_value(t, xml) == checked_span(xml, t.offset + 1, t.ncodeunits - 2)
            elseif t.kind == TokenKinds.PI_OPEN || t.kind == TokenKinds.XML_DECL_OPEN
                @test pi_target(t, xml) == checked_span(xml, t.offset + 2, t.ncodeunits - 2)
            end
            if t.kind == TokenKinds.TEXT || t.kind == TokenKinds.ATTR_VALUE
                @test t.has_entities == occursin('&', r)
            end
        end
    end
end

@testset "token spans are root-relative for SubString input" begin
    # `SubString(::SubString, …)` flattens to the root string, so tokens scanned from a
    # SubString carry root-relative offsets; `raw` resolves the root the same way.
    padded = "x" * MULTIBYTE_DOC * "y"
    sub = SubString(padded, 2, prevind(padded, lastindex(padded)))
    @test sub == MULTIBYTE_DOC
    @test length(collect(tokenize(sub))) == length(collect(tokenize(MULTIBYTE_DOC)))
    for (t, tref) in zip(tokenize(sub), tokenize(MULTIBYTE_DOC))
        @test t.kind == tref.kind
        @test raw(t, sub) == raw(tref, MULTIBYTE_DOC)
        @test raw(t, sub) == checked_span(padded, t.offset, t.ncodeunits)
    end
end

@testset "entity flag and span of a text and of an attribute value, by source type" begin
    # The document is a `String` or a `StringView`, or a `SubString` of one whose parent
    # holds a `&`, a `<` and both quotes on either side of it: a search that left the
    # document would meet them.
    bytes(doc) = StringView(Vector{UInt8}(doc))
    function inner(doc, parent_type = identity)
        parent = parent_type("&<\"'&" * doc * "&<\"'&")
        SubString(parent, 6, prevind(parent, 6 + ncodeunits(doc)))
    end
    sources = (identity, inner, bytes, doc -> inner(doc, bytes))
    # A text or a value of up to 40 bytes holds no `&`, or one at each position in turn.
    # The text lies between two tags, opens the document, or ends it with no `<` after.
    body(len, at) = at == 0 ? "x"^len : "x"^(at - 1) * "&" * "x"^(len - at)
    shapes = (
        (TokenKinds.TEXT, 1, b -> "<a>" * b * "</a>", identity),
        (TokenKinds.TEXT, 1, b -> b * "<a/>", identity),
        (TokenKinds.TEXT, 1, b -> "<a/>" * b, identity),
        (TokenKinds.ATTR_VALUE, 0, b -> "<a b=\"" * b * "\"/>", b -> "\"" * b * "\""),
        (TokenKinds.ATTR_VALUE, 0, b -> "<a b='" * b * "'/>", b -> "'" * b * "'"),
    )
    for source in sources, (kind, shortest, doc, span) in shapes
        wrong = Tuple{Int, Int}[]
        for len in shortest:40, at in 0:len
            b = body(len, at)
            src = source(doc(b))
            t = only(tok for tok in tokenize(src) if tok.kind == kind)
            t.has_entities == (at > 0) && raw(t, src) == span(b) || push!(wrong, (len, at))
        end
        @test isempty(wrong)
    end
    # A `&` next to characters of two, three and four bytes, and none among them.
    multibyte = ("é&é" => true, "€&" => true, "&😀" => true, "日本&語" => true,
                 "é€😀日本語" => false)
    for source in sources, (b, flag) in multibyte
        for (kind, doc) in ((TokenKinds.TEXT, "<a>" * b * "</a>"),
                            (TokenKinds.ATTR_VALUE, "<a b=\"" * b * "\"/>"))
            src = source(doc)
            t = only(tok for tok in tokenize(src) if tok.kind == kind)
            @test t.has_entities == flag
        end
    end
    # A value with no closing quote, cut after its first byte or right after its opening
    # quote: the search stops at the end of a `SubString` document, whose parent holds a
    # quote past it.
    for cut in ("<a b=\"x", "<a b=\""), parent_type in (identity, bytes)
        @test_throws ArgumentError collect(tokenize(parent_type(cut)))
        whole = parent_type(cut * "\"/>")
        @test_throws ArgumentError collect(tokenize(SubString(whole, 1, ncodeunits(cut))))
    end
end

@testset "under Julia 1.10, each source type is searched through its bytes" begin
    # Julia 1.10 searches a `SubString{String}` for a character one character at a time, and
    # a `StringView` at several times the cost of the `memchr` call. Each of these source
    # types has its own search there, apart from the one that goes through the string
    # interface. A `String` keeps that one to find a character: Base runs it with `memchr`.
    if VERSION < v"1.11"
        T = XML.XMLTokenizer
        for S in (String, SubString{String}, StringView{Vector{UInt8}},
                  SubString{StringView{Vector{UInt8}}})
            @test which(T._hasbyte, Tuple{S, UInt8, Int, Int}) !==
                  which(T._hasbyte, Tuple{AbstractString, UInt8, Int, Int})
            S === String && continue
            @test which(T._findchar, Tuple{S, UInt8, Int}) !==
                  which(T._findchar, Tuple{AbstractString, UInt8, Int})
        end
        @test which(T._hasbyte, Tuple{SubString{String}, UInt8}) !==
              which(T._hasbyte, Tuple{AbstractString, UInt8})
        # and so has the search of a comment for `--`
        @test which(XML._has_double_hyphen, Tuple{SubString{String}}) !==
              which(XML._has_double_hyphen, Tuple{AbstractString})
    end
end

@testset "a byte is searched for within a view, not past its ends" begin
    hasbyte = XML.XMLTokenizer._hasbyte
    lt = UInt8('<')
    # The parent holds the byte on either side of the view, which holds it at its first
    # byte, at its last one, or nowhere. The last view is empty, between two of them.
    for len in (1, 2, 15, 16, 17, 64)
        clean = SubString("<" * "x"^len * "<", 2, len + 1)
        @test !hasbyte(clean, lt)
        @test hasbyte(SubString("<<" * "x"^(len - 1) * "<", 2, len + 1), lt)
        @test hasbyte(SubString("<" * "x"^(len - 1) * "<<", 2, len + 1), lt)
    end
    @test !hasbyte(SubString("<<", 2, 1), lt)
    @test !hasbyte("", lt)
    @test hasbyte("a<", lt)
    @test !hasbyte("é€😀", lt)
end

@testset "long texts, attribute values and comments are searched through their bytes" begin
    # A search that decodes each character of a text of some megabytes takes over a hundred
    # times as long as `memchr` over the same bytes. Each operation below makes a few
    # searches of the kind, and takes up to four times as long as `memchr` when they all go
    # through the bytes. The bounds sit between the two, with room for a slow machine; each
    # time is the best of five runs. An operation that also copies the span, or reads it
    # byte by byte, is compared with a neighbor that does the same without the search.
    best(f) = minimum(@elapsed(f()) for _ in 1:5)
    count_tokens(src) = count(Returns(true), tokenize(src))
    long = "x"^(4 * 2^20)
    memchr = best(() -> findnext(==(UInt8('&')), codeunits(long), 1))
    inner(doc) = SubString("<!--x-->" * doc, 9)
    text, attribute = "<a>" * long * "</a>", "<a b=\"" * long * "\"/>"
    for doc in (text, attribute), source in (identity, inner)
        count_tokens(source("<a b=\"x\">y</a>"))      # compiles the readers for this type
        src = source(doc)
        @test best(() -> count_tokens(src)) < 10 * memchr
    end
    # `parse` searches each attribute value for a `<`, and `unescape` a view for a `&`. A
    # `Node` copies the value, which takes longer than the search: its time is compared with
    # that of the `:lenient` level, which makes no such search.
    parse("<a b=\"x\"/>", FlatNode)
    @test best(() -> parse(attribute, FlatNode)) < 20 * memchr
    parse("<a b=\"x\"/>", Node), parse("<a b=\"x\"/>", Node; wellformed = :lenient)
    @test best(() -> parse(attribute, Node)) <
          3 * best(() -> parse(attribute, Node; wellformed = :lenient))
    value = inner(long)
    XML.unescape(inner("x"))
    @test best(() -> XML.unescape(value)) < 10 * memchr
    # A document whose DOCTYPE declares an entity is rewritten before it is read, and each
    # text that holds a `&` is searched for a reference to that entity.
    function walk(src)
        cursor, count = Cursor(src), 0
        while next!(cursor) !== nothing
            count += 1
        end
        count
    end
    dtd = "<!DOCTYPE a [<!ENTITY e \"v\">]>"
    walk(dtd * "<a>&e;<b>&amp;</b></a>")
    @test best(() -> walk(dtd * "<a>&amp;" * long * "</a>")) < 20 * memchr
    # A text that holds such a reference is copied too: its walk is compared with that of a
    # document where the same long text is copied without being searched.
    declared, apart = dtd * "<a>&e;" * long * "</a>", dtd * "<a>&e;<b>" * long * "</b></a>"
    @test best(() -> walk(declared)) < 3 * best(() -> walk(apart))
    # `:strict` searches each comment for `--`, once the tokenizer has read it byte by byte
    # and its characters are checked. Under Julia 1.10, where that search goes through the
    # bytes, its time is compared with that of a CDATA section of the same length, which is
    # read and checked the same way without the search. Later versions run Base's own
    # search.
    if VERSION < v"1.11"
        comment, cdata = "<a><!--" * long * "--></a>", "<a><![CDATA[" * long * "]]></a>"
        for R in (Node, FlatNode)
            parse("<a><!--c--><![CDATA[d]]></a>", R; wellformed = :strict)
            @test best(() -> parse(comment, R; wellformed = :strict)) <
                  3 * best(() -> parse(cdata, R; wellformed = :strict))
        end
    end
end

@testset "empty spans reconstruct as empty strings" begin
    for (xml, k) in (
        ("<!---->", TokenKinds.COMMENT_CONTENT),
        ("<![CDATA[]]>", TokenKinds.CDATA_CONTENT),
        ("<?t?>", TokenKinds.PI_CONTENT),
    )
        t = only(tok for tok in tokenize(xml) if tok.kind == k)
        @test t.ncodeunits == 0
        @test isempty(raw(t, xml))
        @test raw(t, xml) == ""
    end
end

@testset "Token convenience constructors mirror SubString fields" begin
    xml = "<a>té</a>"
    sub = SubString(xml, 4, 5)          # "té" — ends on a 2-byte character
    t1 = Token(TokenKinds.TEXT, sub)
    t2 = Token(TokenKinds.TEXT, true, sub)
    @test (t1.offset, t1.ncodeunits) == (sub.offset, ncodeunits(sub))
    @test (t2.offset, t2.ncodeunits) == (sub.offset, ncodeunits(sub))
    @test !t1.has_entities
    @test t2.has_entities
    @test raw(t1, xml) == "té" == raw(t2, xml)
    # Direct, non-inlined call takes the @boundscheck-validated construction path.
    @test XML.XMLTokenizer._noshift_substring(xml, t1.offset, t1.ncodeunits) == "té"
end

@testset "token views are rebuilt without a deprecated Base constructor" begin
    # Julia 1.14 deprecates the noshift `SubString` constructor for `Base.raw_substring`. A process
    # that turns deprecations into errors reads every kind of token through every reader, so the
    # body this build selected calls nothing deprecated.
    code = """
        using XML
        doc = "<?xml version='1.0'?><!DOCTYPE r><r a='1'><b>t</b><!--c--><![CDATA[d]]><?p x?></r>"
        for R in (Node, FlatNode, LazyNode)
            XML.write(parse(doc, R))
        end
        cur = Cursor(doc)
        while next!(cur) !== nothing
            nodetype(cur) === Element && (tag(cur); attributes(cur))
        end
        """
    mktemp() do path, io
        write(io, code)
        close(io)
        julia = `$(Base.julia_cmd()) --startup-file=no --depwarn=error`
        @test success(run(ignorestatus(`$julia --project=$(Base.active_project()) $path`)))
    end
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
    # Token stores a byte range, not its text, so `show` prints kind + range, not the content.
    tok = first(tokenize("hello"))   # TEXT token spanning the whole input → "@0+5"
    buf = IOBuffer()
    show(buf, tok)
    s = String(take!(buf))
    @test occursin("TEXT", s)
    @test occursin("@0", s)
    @test occursin("+5", s)
end

end # top-level testset
