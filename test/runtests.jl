using XML
using XML: Document, Element, Declaration, Comment, CData, DTD, ProcessingInstruction, Text, escape, unescape, OrderedDict, h
using Downloads: download
using Test
import AbstractTrees

AbstractTrees.children(x::Node) = children(x)

#-----------------------------------------------------------------------------# files
xml_xsd = joinpath("data", "xml.xsd")
kml_xsd = joinpath("data", "kml.xsd")
books_xml = joinpath("data", "books.xml")
example_kml = joinpath("data", "example.kml")
simple_dtd = joinpath("data", "simple_dtd.xml")

all_files = [xml_xsd, kml_xsd, books_xml, example_kml, simple_dtd]

#-----------------------------------------------------------------------------# h
@testset "h function" begin
    @test h.tag == XML.Element("tag")
    @test h.tag(id="id") == XML.Element("tag"; id="id")
    @test h.tag(1, 2, a="a", b="b") == XML.Element("tag", 1, 2; a="a", b="b")
end

#-----------------------------------------------------------------------------# escaping/unescaping
@testset "escaping/unescaping" begin
    s = "This > string < has & some \" special ' characters"
    @test escape(s) == "This &gt; string &lt; has &amp; some &quot; special &apos; characters"
    @test escape(escape(s)) == escape(s)
    @test s == unescape(escape(s))
    @test s == unescape(unescape(escape(s)))

    n = Element("tag", Text(s))
    @test XML.simple_value(n) == s

    XML.escape!(n)
    @test XML.simple_value(n) == escape(s)

    XML.unescape!(n)
    @test XML.simple_value(n) == s
end

#-----------------------------------------------------------------------------# DTD
# @testset "DTDBody and friends" begin
#     s = read(simple_dtd, String)
#     data = read(simple_dtd)

#     dtd = XML.DTDBody(data)
#     dtd2 = parse(s, XML.DTDBody)

#     @test length(dtd.elements) == length(dtd2.elements) == 0
#     @test length(dtd.attributes) == length(dtd2.attributes) == 0
#     @test length(dtd.entities) == length(dtd2.entities) == 3

#     o = read("data/tv.dtd", XML.DTDBody)
# end

#-----------------------------------------------------------------------------# Raw
@testset "Raw tag/attributes/value" begin
    examples = [
        (xml = "<!DOCTYPE html>",
            nodetype = DTD,
            tag=nothing,
            attributes=nothing,
            value="html"),
        (xml = "<?xml version=\"1.0\" key=\"value\"?>",
            nodetype = Declaration,
            tag=nothing,
            attributes=Dict("version" => "1.0", "key" => "value"),
            value=nothing),
        (xml = "<tag _id=\"1\", x=\"abc\" />",
            nodetype = Element,
            tag="tag",
            attributes=Dict("_id" => "1", "x" => "abc"),
            value=nothing),
        (xml = "<!-- comment -->",
            nodetype = Comment,
            tag=nothing,
            attributes=nothing,
            value=" comment "),
        (xml = "<![CData[cdata test]]>",
            nodetype = CData,
            tag=nothing,
            attributes=nothing,
            value="cdata test"),
    ]
    for x in examples
        # @info "Testing: $(x.xml)"
        data = XML.next(XML.parse(x.xml, XML.Raw))
        @test XML.nodetype(data) == x.nodetype
        @test XML.tag(data) == x.tag
        @test XML.attributes(data) == x.attributes
        @test XML.value(data) == x.value
    end
end

@testset "Raw with books.xml" begin
    data = read(books_xml, XML.Raw)
    doc = collect(data)
    @test length(doc) > countlines(books_xml)
    # Check that the first 5 lines are correct
    first_5_lines = [
        XML.RawDeclaration => """<?xml version="1.0"?>""",
        XML.RawElementOpen => "<catalog>",
        XML.RawElementOpen => "<book id=\"bk101\">",
        XML.RawElementOpen => "<author>",
        XML.RawText => "Gambardella, Matthew"
    ]
    for (i, (typ, str)) in enumerate(first_5_lines)
        dt = doc[i]
        @test dt.type == typ
        @test String(dt) == str
    end
    # Check that the last line is correct
    @test doc[end].type == XML.RawElementClose
    @test String(doc[end]) == "</catalog>"

    @testset "next and prev" begin
        @test XML.prev(doc[1]) == data # can't use === here because prev returns a copy of ctx
        @test prev(data) === nothing
        @test XML.next(doc[end]) === nothing

        n = length(doc)
        next_res = [doc[1]]
        foreach(_ -> push!(next_res, XML.next(next_res[end])), 1:n-1)

        prev_res = [doc[end]]
        foreach(_ -> pushfirst!(prev_res, XML.prev(prev_res[1])), 1:n-1)

        idx = findall(next_res .!= prev_res)

        for (a,b) in zip(next_res, prev_res)
            @test a == b
        end

        lzxml = """<root><text>    </text><text2>  hello  </text2><text3 xml:space="preserve">  hello  <text3b>  preserve  </text3b></text3><text4 xml:space="preserve"></text4><text5/></root>"""
        lz = XML.parse(XML.LazyNode, lzxml)
        n=XML.next(lz)
        n=XML.next(n)
        text_content = XML.write(n)
       @test text_content == "<text/>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text2>hello</text2>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "hello"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text3 xml:space=\"preserve\">  hello  <text3b>  preserve  </text3b></text3>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "hello"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text3 xml:space=\"preserve\">  hello  <text3b>  preserve  </text3b></text3>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "  hello  "
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text3b>  preserve  </text3b>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "  preserve  "
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text4 xml:space=\"preserve\"/>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "<text5/>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text4 xml:space=\"preserve\"/>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "  preserve  "
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text3b>  preserve  </text3b>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "  hello  "
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text3 xml:space=\"preserve\">  hello  <text3b>  preserve  </text3b></text3>"
        n=XML.next(n)
        text_content = XML.write(n)
        @test text_content == "  hello  "
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text3 xml:space=\"preserve\">  hello  <text3b>  preserve  </text3b></text3>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "hello"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text2>hello</text2>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<text/>"
        n=XML.prev(n)
        text_content = XML.write(n)
        @test text_content == "<root>\n  <text/>\n  <text2>hello</text2>\n  <text3 xml:space=\"preserve\">  hello  <text3b>  preserve  </text3b></text3>\n  <text4 xml:space=\"preserve\"/>\n  <text5/>\n</root>"
    end

    @testset "depth and parent" begin
        @test XML.depth(data) == 0
        @test isnothing(XML.parent(data))
        @test XML.depth(doc[1]) == 1
        @test XML.parent(doc[1]) == data
        @test XML.depth(doc[2]) == 1
        @test XML.depth(doc[3]) == 2
        @test XML.parent(doc[3]) == doc[2]
        @test XML.depth(doc[end]) == 1
        @test XML.parent(doc[end]) == data
    end

    @testset "tag/attributes/value" begin
        x = doc[1]  # <?xml version="1.0"?>
        @test XML.tag(x) === nothing
        @test XML.attributes(x) == Dict("version" => "1.0")
        @test XML.value(x) === nothing

        x = XML.next(x)  # <catalog>
        @test XML.tag(x) == "catalog"
        @test XML.attributes(x) === nothing
        @test XML.value(x) === nothing

        x = XML.next(x)  # <book id="bk101">
        @test XML.tag(x) == "book"
        @test XML.attributes(x) == Dict("id" => "bk101")
        @test XML.value(x) === nothing

        x = XML.next(x)  # <author>
        @test XML.tag(x) == "author"
        @test XML.attributes(x) === nothing
        @test XML.value(x) === nothing

        x = XML.next(x)  # Gambardella, Matthew
        @test XML.tag(x) === nothing
        @test XML.attributes(x) === nothing
        @test XML.value(x) == "Gambardella, Matthew"
    end
end

#-----------------------------------------------------------------------------# Preserve whitespace
@testset "xml:space" begin
    @testset "Basic xml:space functionality" begin

        # Test 1: xml:space="preserve" should preserve entirely empty whitespace
        xml1 = """<root><text xml:space="preserve">   </text></root>"""
        doc1 = parse(XML.Node, xml1)
        text_content = XML.value(doc1[1][1][1])
        @test text_content == "   "

        # Test 2: xml:space="preserve" should preserve leading and trailing whitespace
        xml2 = """<root><text xml:space="preserve">  leading and trailing spaces  </text></root>"""
        doc2 = parse(XML.Node, xml2)
        text_content = XML.value(doc2[1][1][1])
        @test text_content == "  leading and trailing spaces  "
        
        # Test 3: Entirely empty tags with and without xml:space="preserve" become self-closing
        xml3 = """<root><text>    </text><text2 xml:space="preserve">    </text2><text3 xml:space="preserve"></text3><text4/></root>"""
        doc3 = XML.parse(XML.Node, xml3)
        text_content = XML.write(doc3[1][1])
        @test text_content == "<text/>" # without xml:space="preserve", empty text becomes self-closing
        text_content = XML.value(doc3[1][2][1])
        @test text_content == "    " # with xml:space, whitespace is preserved
        text_content = XML.write(doc3[1][3])
        @test text_content == "<text3 xml:space=\"preserve\"/>" # with xml:space="preserve", empty text becomes self-closing

        # Test 4: Without xml:space, whitespace should be normalized
        xml4 = """<root><text>  gets normalized  </text></root>"""
        doc4 = XML.parse(XML.Node, xml4)
        text_content = XML.value(doc4[1][1][1])
        @test text_content == "gets normalized"
        
        # Test 5: xml:space="default" should normalize even with preserve_xml_space=true
        xml5 = """<root><text xml:space="default">  gets normalized  </text></root>"""
        doc5 = XML.parse(XML.Node, xml5)
        text_content = XML.value(doc5[1][1][1])
        @test text_content == "gets normalized"
    end
    
    @testset "xml:space inheritance" begin
        # Test 6: Children inherit parent's xml:space="preserve"
        xml6 = """<root xml:space="preserve">
            <parent>  parent text  
                <child>  child text  </child>
            </parent>
        </root>"""
        doc6 = XML.parse(XML.Node, xml6)
        # Both parent and child should preserve whitespace
        @test contains(XML.value(doc6[1][2][1]), "parent text  \n")
        @test XML.value(doc6[1][2][2][1]) == "  child text  "
        
        # Test 7: xml:space="default" overrides parent's "preserve"
        xml7 = """<root xml:space="preserve">
            <child xml:space="default">  normalized despite parent  </child>
        </root>"""
        doc7 = XML.parse(XML.Node, xml7)
        @test XML.value(doc7[1][2][1]) == "normalized despite parent"
    end
    
    @testset "Nesting scenarios" begin
        # Test 8: Multiple levels of xml:space changes
        xml8 = """<root xml:space="preserve">
            <level1>  preserved  
                <level2 xml:space="default">  normalized  
                    <level3 xml:space="preserve">  preserved again  </level3>
                </level2>
            </level1>
        </root>"""
        doc8 = XML.parse(XML.Node, xml8)
        
        # level1 should preserve (inherits from root)
        level1_text = XML.value(doc8[1][2][1])
        @test level1_text == "  preserved  \n        "
        
        # level2 should normalize (explicit xml:space="default")
        level2_text = XML.value(doc8[1][2][2][1])
        @test level2_text == "normalized"
        
        # level3 should preserve (explicit xml:space="preserve")
        level3_text = XML.value(doc8[1][2][2][2][1])
        @test level3_text == "  preserved again  "

        # Test 9: repeated multiple levels of xml:space changes
        xml9 = """<root xml:space="preserve">
            <level1>  preserved  
                <level2 xml:space="default">  normalized  
                    <level3 xml:space="preserve">  preserved again  </level3>
                </level2>
            </level1>  
            <level1b>  preserved b  
                <level2b xml:space="default">  normalized b 
                    <level3b xml:space="preserve">  preserved again b  </level3b>
                </level2b>
            </level1b>
        </root>"""
        doc9 = XML.parse(XML.Node, xml9)

        # level1b should preserve (inherits from root)
        level1b_text = XML.value(doc9[1][4][1])
        @test level1b_text == "  preserved b  \n        "
        
        # level2 should normalize (explicit xml:space="default")
        level2b_text = XML.value(doc9[1][4][2][1])
        @test level2b_text == "normalized b"
        
        # level3 should preserve (explicit xml:space="preserve")
        level3b_text = XML.value(doc9[1][4][2][2][1])
        @test level3b_text == "  preserved again b  "

        # Test 10: futher repeated multiple levels of xml:space changes
        xml10 = """<root>
            <level1>  normalized  
                <level2>  normalized b  
                    <level3 xml:space="preserve">  preserved   </level3>
                </level2>
            </level1>  
            <level1b>  normalized c  
                <level2b xml:space="preserve">  preserved b 
                    <level3b xml:space="default">  normalized again b  </level3b>
                    <level3c>  preserved c 
                    </level3c>
                </level2b>
            </level1b>
            <level1c>  normalized d   </level1c>
        </root>"""
        doc10 = XML.parse(XML.Node, xml10)
        
        # level1 should normalize (as root)
        level1_text = XML.value(doc10[end][1][1])
        @test level1_text == "normalized"
        
        # level2 should normalize (as root and level1)
        level2_text = XML.value(doc10[end][1][2][1])
        @test level2_text == "normalized b"
        
        # level3 should preserve (explicit xml:space="preserve")
        level3_text = XML.value(doc10[end][1][2][2][1])
        @test level3_text == "  preserved   "
        
        # level1b should normalize (as root)
        level1b_text = XML.value(doc10[end][2][1])
        @test level1b_text == "normalized c"
        
        # level2b should preserve (explicit xml:space="preserve")
        level2b_text = XML.value(doc10[end][2][2][1])
        @test level2b_text == "  preserved b \n            "
        
        # level3 should normalize (explicit xml:space="default")
        level3b_text = XML.value(doc10[end][2][2][2][1])
        @test level3b_text == "normalized again b"
        
        # level3c should preserve (inherited from level2b)
        level3c_text = XML.value(doc10[end][2][2][4][1])
        @test level3c_text == "  preserved c \n            "
        
        # level1c should normalize (as root)
        level1c_text = XML.value(doc10[end][3][1])
        @test level1c_text == "normalized d"
    end
    @testset "inter-element gap semantics" begin
        # Default parent: gap between siblings should be dropped
        s1 = """<root><a> x </a>
                <b> y </b></root>"""
        d1 = XML.parse(XML.Node, s1)
        @test length(d1[1]) == 2
        @test XML.value(d1[1][1][1]) == "x"
        @test XML.value(d1[1][2][1]) == "y"

        # Preserve parent, default child ends: gap after default child dropped
        s2 = """<root xml:space="preserve">
                  <p> keep  </p>
                  <q xml:space="default">  norm  </q>
                  <r>  after default gap  </r>
                </root>"""
        d2 = XML.parse(XML.Node, s2)
        @test length(d2[1]) == 7
        @test XML.value(d2[1][1]) == "\n  "
        @test XML.value(d2[1][2][1]) == " keep  "
        @test XML.value(d2[1][3]) == "\n  "
        @test XML.value(d2[1][4][1]) == "norm"
        @test XML.value(d2[1][5]) == "\n  "
        @test XML.value(d2[1][6][1]) == "  after default gap  "
        @test XML.value(d2[1][7]) == "\n"
    end
    @testset "XML whitespace vs Unicode whitespace" begin
        nbsp = "\u00A0"
        s = """<root>
                 <a>  x\t\n  </a>
                 <b>$(nbsp) y $(nbsp)</b>
                 <c xml:space="default">$(nbsp)  z  $(nbsp)</c>
               </root>"""
        d = XML.parse(XML.Node, s)
        @test XML.value(d[1][1][1]) == "x"
        @test XML.value(d[1][2][1]) == "$(nbsp) y $(nbsp)"
        @test XML.value(d[1][3][1]) == "$(nbsp)  z  $(nbsp)"
    end

    @testset "CDATA/Comment/PI boundaries" begin
        s = """<root>
                 <a xml:space="default">  pre  <![CDATA[  mid  ]]>  post  </a>
                 <b xml:space="preserve">  pre  <!-- cmt -->  post  </b>
                 <?xml-stylesheet type="text/css" href="style.css"?>
               </root>"""
        d = XML.parse(XML.Node, s)
        @test XML.value(d[1][1][1]) == "pre"
        @test nodetype(d[1][1][2]) == XML.CData
        @test XML.value(d[1][1][3]) == "post"
        @test XML.value(d[1][2][1]) == "  pre  "
        @test nodetype(d[1][2][2]) == XML.Comment
        @test XML.value(d[1][2][3]) == "  post  "
        @test nodetype(d[1][3]) == XML.ProcessingInstruction
    end

    @testset "nested toggles and sibling sequences" begin
        s = """<root xml:space="preserve">
                 <x>  a  
                   <y xml:space="default">  b  
                     <z xml:space="preserve">  c  </z>
                   </y>
                   <y2 xml:space="default">  d  </y2>
                   <w>  e  </w>
                 </x>
               </root>"""
        d = XML.parse(XML.Node, s)
        @test XML.value(d[1][2][1]) == "  a  \n    "
        @test XML.value(d[1][2][2][1]) == "b"
        @test XML.value(d[1][2][2][2][1]) == "  c  "
        @test d[1][2][4].tag == "y2"
        @test XML.value(d[1][2][4][1]) == "d"
        @test d[1][2][6].tag == "w"
        @test XML.value(d[1][2][6][1]) == "  e  "
    end

    @testset "root/document boundaries" begin
        s = "\n  \n<root>  a  </root>\n \t "
        d = XML.parse(XML.Node, s)
        @test length(d) == 1
        @test XML.value(d[1][1]) == "a"
    end

    @testset "entities expanding to whitespace" begin
        chr1="\u0020"
        chr2="\u000A"
        chr3="\u00A0"
        
        s = """<root>
                 <a> $(chr1) a $(chr2) </a>
                 <b xml:space="preserve">$(chr1) b $(chr2)</b>
                 <c>$(chr3)c$(chr3)</c>
               </root>"""
        d = XML.parse(XML.Node, s)
        @test XML.value(d[1][1][1]) == "a"
        @test XML.value(d[1][2][1]) == "  b \n"
        @test XML.value(d[1][3][1]) == "$(chr3)c$(chr3)"
    end

    @testset "invalid values and placement" begin
        s_bad = """<root><x xml:space="weird"> t </x></root>"""
        @test_throws ErrorException XML.parse(XML.Node, s_bad)

        s_pi = """<?pi xml:space="preserve"?><root> t </root>"""
        d = XML.parse(XML.Node, s_pi)
        @test XML.value(d[end][1]) == "t"

        s_dup = """<root><x xml:space="preserve" xml:space="default">  t  </x></root>"""
#        @test_throws ErrorException XML.parse(XML.Node, s_dup)
    end

    @testset "prev()/next() symmetry" begin
        xml = """<root xml:space="preserve">
                    <a>  a  <b xml:space="default">  b  </b>  <c>  c  </c>  </a>
                    <d xml:space="default">  d  <e xml:space="preserve">  e  </e>  f  </d>
                    <g><h/><i xml:space="preserve">  i  </i><j/></g>
                 </root>"""
        r = XML.parse(XML.LazyNode, xml).raw
        toks=XML.Raw[]
        while true
            n = XML.next(r)
            n === nothing && break
            push!(toks, n)
            r=n
        end
        back = XML.Raw[]
        r = toks[end]
        while true
            p = XML.prev(r)
            p === nothing && break
            push!(back, p)
            r = p
        end
        @test reverse(back)[2:end] == toks[1:end-1]
    end

    @testset "write/read roundtrip extremes" begin
        xml = """<root>
                   <p xml:space="preserve">    </p>
                   <q>   </q>
                   <r xml:space="default">  r  </r>
                   <s xml:space="preserve"> pre <t/> post </s>
                 </root>"""
        n = XML.parse(XML.Node, xml)
        io = IOBuffer(); XML.write(io, n)
        n2 = XML.parse(XML.Node, String(take!(io)))
        @test n == n2
        @test XML.write(n2[1][1]) == "<p xml:space=\"preserve\">    </p>"
        @test XML.write(n2[1][2]) == "<q/>"
        @test XML.value(n2[1][3][1]) == "r"
        @test XML.write(n2[1][4]) == "<s xml:space=\"preserve\"> pre <t/> post </s>"
   end

    @testset "self-closing/empty/whitespace-only children" begin
        s = """<root>
                 <a xml:space="default">    </a>
                 <b xml:space="preserve"></b>
                 <c xml:space="preserve">   </c>
                 <d><e/></d>
                 <f> x <g/> y </f>
               </root>"""
        d = XML.parse(XML.Node, s)
        @test XML.write(d[1][1]) == "<a xml:space=\"default\"/>"
        @test XML.write(d[1][2]) == "<b xml:space=\"preserve\"/>"
        @test XML.value(d[1][3][1]) == "   "
        @test XML.value(d[1][5][1]) == "x"
        @test XML.value(d[1][5][3]) == "y"
    end

    @testset "allocation guard: small xml:space doc" begin
        xml = "<root><a xml:space=\"default\"> x </a><b xml:space=\"preserve\"> y </b></root>"
        f() = XML.parse(XML.Node, xml)
        a = @allocated f()
        @test a < 500_000  # tune for CI
    end

end

#-----------------------------------------------------------------------------# roundtrip
@testset "read/write/read roundtrip" begin
    for path in all_files
        node = read(path, Node)
        temp = tempname() * ".xml"
        XML.write(temp, node)
        node2 = read(temp, Node)
        @test node == node2

        #For debugging:
        for (a,b) in zip(AbstractTrees.Leaves(node), AbstractTrees.Leaves(node2))
            if a != b
                @info path
                @info a
                @info b
                error()
            end
        end
    end
end

#-----------------------------------------------------------------------------# Node writing
@testset "Node writing" begin
    doc = Document(
        DTD("root_tag"),
        Declaration(version=1.0),
        Comment("comment"),
        ProcessingInstruction("xml-stylesheet", href="mystyle.css", type="text/css"),
        Element("root_tag", CData("cdata"), Text("text"))
    )
    @test map(nodetype, children(doc)) == [DTD,Declaration,Comment,ProcessingInstruction,Element]
    @test length(children(doc[end])) == 2
    @test nodetype(doc[end][1]) == XML.CData
    @test nodetype(doc[end][2]) == XML.Text
    @test value(doc[end][1]) == "cdata"
    @test value(doc[end][2]) == "text"

    #set/get index for attributes
    o = doc[end]
    @test isempty(keys(o))
    o["id"] = 1
    @test o["id"] == "1"
    @test keys(o) == keys(Dict("id" => "1"))
end

#-----------------------------------------------------------------------------# Issues
@testset "Issues" begin
    # https://github.com/JuliaComputing/XML.jl/issues/12: DTD content was cut short
    s = """
    <!DOCTYPE note [
    <!ENTITY nbsp "&#xA0;">
    <!ENTITY writer "Writer: Donald Duck.">
    <!ENTITY copyright "Copyright: W3Schools.">
    ]>
    """

    doc = parse(Node, s)
    @test value(only(doc)) == s[11:end-2]  # note [...]

    # https://github.com/JuliaComputing/XML.jl/issues/14 (Sorted Attributes)
    kw = NamedTuple(OrderedDict(Symbol(k) => Int(k) for k in 'a':'z'))
    xyz  = XML.Element("point"; kw...)
    @test collect(keys(attributes(xyz))) == string.(collect('a':'z'))

    # https://github.com/JuliaComputing/XML.jl/issues/62 (UTF-16/BOM input)
    text = """<?xml version="1.0"?><root>hello</root>"""
    units = transcode(UInt16, text)
    le = vcat(UInt8[0xFF, 0xFE], reinterpret(UInt8, units))
    be = vcat(UInt8[0xFE, 0xFF], reinterpret(UInt8, bswap.(units)))
    utf8_bom = vcat(UInt8[0xEF, 0xBB, 0xBF], Vector{UInt8}(text))
    for bytes in (le, be, utf8_bom)
        doc = Node(XML.Raw(bytes))
        root = only(filter(n -> nodetype(n) == Element, children(doc)))
        @test tag(root) == "root"
        @test value(only(children(root))) == "hello"

        # read(file) round-trip exercises the Mmap.mmap path (the real .xlsx case)
        mktemp() do path, io
            write(io, bytes)
            close(io)
            file_doc = read(path, Node)
            file_root = only(filter(n -> nodetype(n) == Element, children(file_doc)))
            @test tag(file_root) == "root"
            @test value(only(children(file_root))) == "hello"
        end
    end
end

