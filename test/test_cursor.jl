using Test, XML, StringViews
using XML: Cursor, next!, for_each_child!, @for_each_child!, skip_element!, eof, nodetype,
           tag, value, attributes, depth, children, Element, Text, CData, Comment,
           ProcessingInstruction, Declaration, DTD, LazyNode, is_simple_value, is_simple,
           simple_value

@testset "Cursor" begin

    @testset "depth + nodetype + tag/value walk" begin
        doc = """<r><a x="1">t1<b/></a><c>t2</c></r>"""
        # Hand-counted DFS (root children at depth 1):
        expected = [
            (Element, 1, "r",  nothing),
            (Element, 2, "a",  nothing),
            (Text,    3, nothing, "t1"),
            (Element, 3, "b",  nothing),
            (Element, 2, "c",  nothing),
            (Text,    3, nothing, "t2"),
        ]
        c = parse(Cursor, doc)
        got = []
        while next!(c) !== nothing
            t = nodetype(c) === Element ? (tag(c) === nothing ? nothing : String(tag(c))) : nothing
            v = nodetype(c) === Text ? String(value(c)) : nothing
            push!(got, (nodetype(c), depth(c), t, v))
        end
        @test got == expected
        @test eof(c)
        @test next!(c) === nothing          # idempotent at eof
    end

    @testset "for_each_child! yields immediate children only" begin
        doc = """<r><a><deep/></a><c/><e/></r>"""
        c = parse(Cursor, doc)
        next!(c)                            # position at <r>
        @test String(tag(c)) == "r"
        kids = String[]
        for_each_child!(c) do ch
            push!(kids, String(tag(ch)))
        end
        @test kids == ["a", "c", "e"]       # <deep> is a grandchild, excluded
    end

    # The old names walk the same way, and warn when they run, until they go in v0.5.
    @testset "for_each_child and @for_each_child: deprecated names of the same walk" begin
        # <z/> follows the subtree of <r>: the walk stops on it, and holds it for the next
        # next!, as the new names do.
        doc = "<d><r><a><deep/></a><c/><e/></r><z/></d>"
        at_r() = (c = parse(Cursor, doc); next!(c); next!(c); c)
        holds_z(c) = tag(c) == "z" && next!(c) !== nothing && tag(c) == "z"
        kids = String[]
        cur = at_r()
        @test_deprecated XML.for_each_child(ch -> push!(kids, String(tag(ch))), cur)
        @test kids == ["a", "c", "e"]
        @test holds_z(cur)

        # The macro warns when its loop runs, not when a call to it is expanded, and once
        # per session: `XML.__init__` lowers its flag at each load.
        kids = String[]
        cur = at_r()
        call = :(XML.@for_each_child $cur ch push!($kids, String(tag(ch))))
        loop = @test_logs macroexpand(@__MODULE__, call)
        XML._FOR_EACH_CHILD_MACRO_WARNED[] = false
        @test_deprecated eval(loop)
        @test kids == ["a", "c", "e"]
        @test holds_z(cur)
        again = macroexpand(@__MODULE__, :(XML.@for_each_child $(at_r()) ch nothing))
        @test_logs eval(again)
        XML.__init__()
        @test !XML._FOR_EACH_CHILD_MACRO_WARNED[]

        @test_logs XML.for_each_child!(ch -> nothing, at_r())
        newloop = macroexpand(@__MODULE__, :(XML.@for_each_child! $(at_r()) ch nothing))
        @test_logs eval(newloop)
    end

    @testset "attributes + get" begin
        c = parse(Cursor, """<root a="1" b="two" c="&lt;x&gt;"/>""")
        next!(c)
        @test get(c, "a", nothing) == "1"
        @test get(c, "b", nothing) == "two"
        @test get(c, "c", nothing) == "<x>"          # entity-decoded
        @test get(c, "missing", "dflt") == "dflt"
        attrs = attributes(c)
        @test attrs !== nothing
        @test attrs["a"] == "1"
        @test attrs["c"] == "<x>"
    end

    @testset "by-key getindex/haskey/keys" begin
        # #100 — the KeyError twin of `get`, plus haskey/keys, on the current node
        c = parse(Cursor, """<root a="1" c="&lt;x&gt;"/>""")
        next!(c)
        @test c["a"] == "1"
        @test c["c"] == "<x>"                            # entity-decoded
        @test_throws KeyError c["missing"]
        @test haskey(c, "a") && !haskey(c, "missing")
        @test collect(keys(c)) == ["a", "c"]
    end

    @testset "eachattribute! reads the attributes where the cursor stands" begin
        # The pairs that eachattribute(LazyNode(c)) gives, read once: the nodes and depths that
        # next! yields afterwards are those of a walk that reads no attribute.
        xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" *
              "<r a=\"1\"><c r=\"A1\" s=\"1\" t=\"s\"><v>0</v></c><c r=\"B1\"/>" *
              "<d a=\"x &amp; y\" b=' p\tq\r\n r ' c=\"&#65;\"/><e/><f></f>t" *
              "<g h=\"1\"><g h=\"2\"/></g><x a='1' b=\"2\"   /></r>"
        function walk(xml, read)
            c = Cursor(xml)
            out = Any[]
            while next!(c) !== nothing
                push!(out, (nodetype(c), tag(c), depth(c)))
                read && nodetype(c) in (Element, Declaration) || continue
                pairs = collect(eachattribute!(c))
                @test pairs == collect(eachattribute(LazyNode(c)))
                @test collect(eachattribute!(c)) == pairs          # a second read, from the `<`
            end
            out
        end
        @test walk(xml, true) == walk(xml, false)
        c = Cursor(xml); next!(c); next!(c); next!(c)                # the declaration, "\n", <r>
        @test tag(c) == "r"
        @test eltype(eachattribute!(c)) == Pair{SubString{String}, SubString{String}}
        @test collect(eachattribute!(c)) == ["a" => "1"]

        # Under for_each_child!, with skip_element!, and on a node an inner sweep holds.
        c = Cursor("<r><a x=\"1\"><b y=\"2\"/></a><s z=\"3\"><t/></s><n w=\"4\"/></r>")
        next!(c)
        seen = Pair{String, Vector{Pair{SubString{String}, SubString{String}}}}[]
        for_each_child!(c) do ch
            t = String(tag(ch))     # `ch` is the cursor: the inner sweep moves it on
            push!(seen, t => collect(eachattribute!(ch)))
            t == "a" && for_each_child!(g -> push!(seen, tag(g) => collect(eachattribute!(g))), ch)
            t == "s" && skip_element!(ch)
        end
        @test seen == ["a" => ["x" => "1"], "b" => ["y" => "2"], "s" => ["z" => "3"], "n" => ["w" => "4"]]

        # Each loop gives all the pairs, from the first: after `first` or `isempty`, on a second
        # read, once the cursor has moved on, and when next! moves it in the middle of a loop.
        # next! skips whatever the cursor has not read.
        all3 = ["a" => "1", "b" => "2", "d" => "3"]
        on_c() = (c = Cursor("<r><c a=\"1\" b=\"2\" d=\"3\"><v>x</v></c><e/></r>"); next!(c); next!(c); c)
        c = on_c()
        it = eachattribute!(c)
        @test first(it) == ("a" => "1")
        @test collect(it) == all3
        @test collect(eachattribute!(c)) == all3
        next!(c)
        @test (nodetype(c), tag(c), depth(c)) == (Element, "v", 3)
        @test collect(it) == all3
        c = on_c(); collect(eachattribute!(c))
        it = eachattribute!(c)
        @test first(it) == ("a" => "1")
        @test collect(it) == all3
        c = on_c(); it = eachattribute!(c)
        @test !isempty(it)
        @test collect(it) == all3
        c = on_c(); seen = Pair{SubString{String}, SubString{String}}[]
        for p in eachattribute!(c)
            push!(seen, p)
            length(seen) == 1 && next!(c)
        end
        @test seen == all3
        @test tag(c) == "v"
        c = on_c(); it = eachattribute!(c)
        skip_element!(c)
        @test collect(it) == all3
        next!(c)
        @test tag(c) == "e"

        # The values stay valid once the cursor has moved on.
        c = Cursor("<r><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\"/></r>"); next!(c); next!(c)
        pairs = collect(eachattribute!(c))
        while next!(c) !== nothing end
        @test pairs == ["r" => "A1", "t" => "s"]

        # Nothing on a node without attributes, and the same pairs over another string type.
        c = Cursor("<r>t<!--x--></r>"); next!(c); next!(c)
        @test isempty(collect(eachattribute!(c)))
        next!(c)
        @test isempty(collect(eachattribute!(c)))
        c = Cursor(SubString("..<r a=\"1\" b=\"&lt;\"/>", 3)); next!(c)
        @test collect(eachattribute!(c)) == ["a" => "1", "b" => "<"]

        # A tag that next! refuses raises the same error in the loop, once the pairs that
        # stand before the defect are given, and the walk still refuses it.
        err_of(f) = try f(); "no error" catch e; sprint(showerror, e) end
        for (bad, before) in ("<a b><c/></a>" => 0, "<a b=c/>" => 0, "<a x=\"1\" b=\"1" => 1,
                              "<a x=\"1\" y='2' \"z\"/>" => 2, "<a b=\"1\" c/>" => 1,
                              "<a x=\"1\" b = " => 1, "<a b" => 0, "<a" => 0)
            c1 = Cursor(bad); next!(c1)
            walked = err_of(() -> next!(c1))
            @test startswith(walked, "ArgumentError")
            c2 = Cursor(bad); next!(c2)
            given = Pair{SubString{String}, SubString{String}}[]
            @test err_of(() -> foreach(p -> push!(given, p), eachattribute!(c2))) == walked
            @test length(given) == before
            @test err_of(() -> collect(eachattribute!(c2))) == walked     # read again from the `<`
            @test err_of(() -> next!(c2)) == walked
        end
    end

    @testset "value of CData / Comment / PI / DTD / Text-with-entities" begin
        c = parse(Cursor, "<r><![CDATA[c<d>ata]]><!--cmt--><?pi body?><t>a&amp;b</t></r>")
        vals = Dict{Any,Any}()
        while next!(c) !== nothing
            nt = nodetype(c)
            if nt === CData
                vals[:cdata] = String(value(c))
            elseif nt === Comment
                vals[:comment] = String(value(c))
            elseif nt === ProcessingInstruction
                vals[:pi_tag] = String(tag(c)); vals[:pi_val] = String(value(c))
            elseif nt === Text
                vals[:text] = String(value(c))
            end
        end
        @test vals[:cdata]   == "c<d>ata"
        @test vals[:comment] == "cmt"
        @test vals[:pi_tag]  == "pi"
        @test vals[:pi_val]  == "body"
        @test vals[:text]    == "a&b"           # entity-decoded
    end

    @testset "accessors agree with LazyNode (token-layer consistency)" begin
        # The cursor computes tag/value/attributes independently of LazyNode but
        # must agree with it node-for-node.
        doc = """<root id="7"><name>Hello</name><![CDATA[raw<x>]]><empty/></root>"""
        c = parse(Cursor, doc)
        while next!(c) !== nothing
            ln = LazyNode(c)                # snapshot bridge
            @test nodetype(c) === nodetype(ln)
            @test tag(c) == tag(ln)
            @test value(c) == value(ln)
            @test get(c, "id", nothing) == get(ln, "id", nothing)
        end
    end

    @testset "snapshot survives further advances" begin
        c = parse(Cursor, "<r><a/><b/></r>")
        next!(c); next!(c)                  # → <a>
        @test String(tag(c)) == "a"
        snap = LazyNode(c)                  # freeze <a>
        next!(c)                            # → <b> (cursor mutated)
        @test String(tag(c)) == "b"
        @test String(tag(snap)) == "a"      # snapshot unchanged
    end

    @testset "iterator protocol" begin
        c = parse(Cursor, "<r><a/><b/></r>")
        tags = String[]
        for node in c
            nodetype(node) === Element && push!(tags, String(tag(node)))
        end
        @test tags == ["r", "a", "b"]
    end

    @testset "empty / self-closing root" begin
        c = parse(Cursor, "<root/>")
        @test next!(c) !== nothing
        @test nodetype(c) === Element
        @test String(tag(c)) == "root"
        @test depth(c) == 1
        @test next!(c) === nothing
    end

    @testset "nested for_each_child! composes (DFS), incl. minified" begin
        # Regression: a consume-on-break for_each_child! skipped the *second* subtree of
        # a parent when there was no inter-element whitespace to buffer the boundary node
        # (the boundary node was consumed by the enclosing sweep's next!). The peekable
        # `held` flag holds the boundary node so composition is correct for any input.
        function folders(doc)
            c = parse(Cursor, doc); next!(c)        # position at <Document>
            out = Tuple{String,Vector{String}}[]
            for_each_child!(c) do _
                nodetype(c) === Element || return
                ftag = String(tag(c))               # capture before descending (aliasing contract)
                kids = String[]
                for_each_child!(c) do _
                    nodetype(c) === Element && push!(kids, String(tag(c)))
                end
                push!(out, (ftag, kids))
            end
            out
        end
        mini = "<Document><Folder><name>F1</name><Placemark/><Placemark/></Folder>" *
               "<Folder><name>F2</name><Placemark/></Folder></Document>"
        ws   = "<Document>\n  <Folder><name>F1</name><Placemark/><Placemark/></Folder>\n" *
               "  <Folder><name>F2</name><Placemark/></Folder>\n</Document>"
        expected = [("Folder", ["name", "Placemark", "Placemark"]), ("Folder", ["name", "Placemark"])]
        @test folders(mini) == expected      # minified — the case the consume-on-break code broke
        @test folders(ws)   == expected      # whitespaced — must still hold

        # 3-level DFS, minified
        c = parse(Cursor, "<D><F><P><a/><b/></P><P><c/></P></F></D>"); next!(c)
        deep = Tuple{String,Vector{String}}[]
        for_each_child!(c) do _              # F
            nodetype(c) === Element || return
            for_each_child!(c) do _          # P
                nodetype(c) === Element || return
                ptag = String(tag(c)); ks = String[]
                for_each_child!(c) do _
                    nodetype(c) === Element && push!(ks, String(tag(c)))
                end
                push!(deep, (ptag, ks))
            end
        end
        @test deep == [("P", ["a", "b"]), ("P", ["c"])]
    end

    @testset "Cursor(data, startpos) + Cursor(LazyNode) subtree bridge" begin
        doc = "<r><a><x/><y/></a><b/></r>"
        # Primitive: start at the byte offset of <a> → walk a's subtree only.
        apos = first(findfirst("<a>", doc))
        c = @test_deprecated Cursor(doc, apos)
        @test next!(c) !== nothing
        @test String(tag(c)) == "a"
        @test depth(c) == 1
        kids = String[]
        @for_each_child! c ch begin
            nodetype(ch) === Element && push!(kids, String(tag(ch)))
        end
        @test kids == ["x", "y"]          # b is a's sibling, outside the subtree → excluded

        # Bridge: locate <a> via the lazy DOM, then cursor-walk just its subtree.
        ln = parse(doc, LazyNode)
        a = children(children(ln)[1])[1]  # Document → <r> → <a>
        c2 = Cursor(a)
        next!(c2)
        @test String(tag(c2)) == "a"
        kids2 = String[]
        @for_each_child! c2 ch begin
            nodetype(ch) === Element && push!(kids2, String(tag(ch)))
        end
        @test kids2 == ["x", "y"]
    end

    @testset "@for_each_child! inlines (accumulates locals without a closure)" begin
        # The macro body assigns enclosing locals directly — the case a do-block
        # would box. Verify correctness of such accumulation, nested + minified.
        doc = "<D><F><P><name>A</name><Point/></P><P><name>B</name></P></F></D>"
        c = parse(Cursor, doc); next!(c)              # at <D>
        placemarks = Tuple{Int,Bool}[]                # (child_element_count, saw_name)
        @for_each_child! c f begin                    # F
            nodetype(f) === Element || continue
            @for_each_child! c p begin                # P
                nodetype(p) === Element || continue
                n = 0; saw_name = false               # locals mutated inside the inner macro body
                @for_each_child! c g begin
                    if nodetype(g) === Element
                        n += 1
                        tag(g) == "name" && (saw_name = true)
                    end
                end
                push!(placemarks, (n, saw_name))
            end
        end
        @test placemarks == [(2, true), (1, true)]    # P1: name+Point; P2: name
    end

    @testset "skip_element! skips a subtree (robust: CDATA/comment/quoted/nested)" begin
        # skip_element! must leave the cursor exactly where for_each_child!'s full walk
        # would on the next sibling — but without tokenizing the skipped subtree, even
        # when it contains a literal </tag> inside CDATA/comments or a > inside an attr.
        kids_plain(doc) = begin
            c = parse(Cursor, doc); next!(c); t = String[]
            for_each_child!(c) do _
                nodetype(c) === Element && push!(t, String(tag(c)))
            end
            t
        end
        kids_skip(doc) = begin
            c = parse(Cursor, doc); next!(c); t = String[]
            for_each_child!(c) do _
                if nodetype(c) === Element
                    push!(t, String(tag(c)))
                    skip_element!(c)
                end
            end
            t
        end
        cases = [
            ("<r><a><x/><y/></a><b>t</b><c/></r>",             ["a", "b", "c"]),
            ("<r><a/><b><z/></b></r>",                         ["a", "b"]),     # self-close first
            ("<r><a><![CDATA[</a> <b> fake]]></a><b/></r>",    ["a", "b"]),     # fake close in CDATA
            ("<r><a><!-- </a><b><c> --></a><d/></r>",          ["a", "d"]),     # fake tags in comment
            ("<r><a><!--></a>--></a><d/></r>",                 ["a", "d"]),     # comment text opens with >
            ("<r><a><!---></a>--></a><d/></r>",                ["a", "d"]),     # comment text opens with ->
            ("<r><a><![CDATA[]]></a><d/></r>",                 ["a", "d"]),     # empty CDATA section
            ("""<r><a x="1>2"><y/></a><b/></r>""",             ["a", "b"]),     # > inside attr value
            ("<r><a><a><a/></a></a><b/></r>",                  ["a", "b"]),     # nested same name
            ("<r><a><?pi <x> ?></a><b/></r>",                  ["a", "b"]),     # markup-ish PI body
            ("<r><a><?></a>?></a><d/></r>",                    ["a", "d"]),     # PI text opens with >
            ("<D><F><P><name>n</name></P></F><F><P/></F></D>", ["F", "F"]),     # minified
        ]
        for (doc, exp) in cases
            @test kids_plain(doc) == exp
            @test kids_skip(doc) == exp
        end

        # On an element that the cursor has left already, skip_element! does nothing: a
        # second call does not close the element once more.
        c = Cursor("<r><a><x/></a><b/><d/></r>"); next!(c); next!(c)           # on <a>
        skip_element!(c); skip_element!(c)
        next!(c); @test (tag(c), depth(c)) == ("b", 2)
        skip_element!(c); skip_element!(c)                                     # `<b/>` closes itself
        next!(c); @test (tag(c), depth(c)) == ("d", 2)
    end

    @testset "is_simple_value(::Cursor) — agrees with LazyNode, non-destructive" begin
        at_v(doc) = (c = parse(Cursor, doc); next!(c); next!(c); c)   # position on <v>
        # simple text / entity / CDATA element → decoded value, identical to the DOM path
        for doc in ("<r><v>123</v></r>", "<r><v>a &amp; b</v></r>", "<r><v><![CDATA[x<y]]></v></r>")
            c = at_v(doc)
            @test String(tag(c)) == "v"
            @test is_simple_value(c) == is_simple_value(LazyNode(c))   # cursor == LazyNode
        end
        @test is_simple_value(at_v("<r><v>123</v></r>"))        == "123"
        @test is_simple_value(at_v("<r><v>a &amp; b</v></r>"))  == "a & b"   # entity-decoded
        @test is_simple_value(at_v("<r><v><![CDATA[x<y]]></v></r>")) == "x<y"

        # not simple → nothing: attribute, element child, empty/self-close, mixed content
        for doc in ("""<r><v a="1">x</v></r>""", "<r><v><b/></v></r>", "<r><v/></r>", "<r><v>a<b/>c</v></r>")
            @test is_simple_value(at_v(doc)) === nothing
        end
        # non-element node → nothing
        c = parse(Cursor, "<r>text</r>"); next!(c); next!(c)
        @test is_simple_value(c) === nothing

        # non-destructive: the cursor is unchanged after the read (still on <v>)
        c = at_v("<r><v>9</v></r>"); is_simple_value(c)
        @test String(tag(c)) == "v" && is_simple_value(c) == "9"
    end

    @testset "is_simple and simple_value(::Cursor) — read as is_simple_value reads" begin
        at_v(doc) = (c = parse(Cursor, doc); next!(c); next!(c); c)   # position on <v>
        for doc in ("<r><v>123</v></r>", "<r><v>a &amp; b</v></r>", "<r><v><![CDATA[x<y]]></v></r>")
            c = at_v(doc)
            @test is_simple(c)
            @test simple_value(c) == is_simple_value(c) == simple_value(LazyNode(c))
        end
        for doc in ("""<r><v a="1">x</v></r>""", "<r><v><b/></v></r>", "<r><v/></r>", "<r><v>a<b/>c</v></r>")
            c = at_v(doc)
            @test !is_simple(c)
            @test_throws ErrorException simple_value(c)
        end
        c = parse(Cursor, "<r>text</r>"); next!(c); next!(c)        # on the Text node
        @test !is_simple(c)
        @test_throws ErrorException simple_value(c)
        # non-destructive, as is_simple_value is: the cursor stays on <v>
        c = at_v("<r><v>9</v></r>"); is_simple(c); simple_value(c)
        @test String(tag(c)) == "v" && simple_value(c) == "9"
    end

    @testset "entry points align with the tree readers (#89)" begin
        xml = """<?xml version="1.0"?><root a="é"><child>texte</child></root>"""
        eltags(cur) = (ts = String[];
                       while next!(cur) !== nothing
                           nodetype(cur) === XML.Element && push!(ts, String(tag(cur)))
                       end;
                       ts)

        # reader-second parse, like the other readers
        @test eltags(parse(xml, Cursor)) == eltags(Cursor(xml)) == ["root", "child"]

        # read from a stream
        @test eltags(read(IOBuffer(xml), Cursor)) == ["root", "child"]

        # read from a file: same acceptance as read(filename, Node) — BOM handling included
        # (UTF-8 BOM strip; UTF-16 LE/BE transcoding, which the Cursor(str) constructor's
        # decoded-U+FEFF drop alone cannot provide)
        dir = mktempdir()
        u16 = transcode(UInt16, xml)
        variants = ["utf8_plain" => Vector{UInt8}(xml),
                    "utf8_bom"   => vcat([0xEF, 0xBB, 0xBF], Vector{UInt8}(xml)),
                    "utf16_le"   => collect(reinterpret(UInt8, vcat(UInt16(0xFEFF), u16))),
                    "utf16_be"   => collect(reinterpret(UInt8, bswap.(vcat(UInt16(0xFEFF), u16))))]
        for (name, bytes) in variants
            f = joinpath(dir, name * ".xml")
            write(f, bytes)
            cur = read(f, Cursor)
            seen = String[]
            aval = nothing
            while next!(cur) !== nothing
                nodetype(cur) === XML.Element || continue
                push!(seen, String(tag(cur)))
                tag(cur) == "root" && (aval = String(attributes(cur)["a"]))
            end
            @test seen == ["root", "child"]
            @test aval == "é"
        end

        # BOM-less UTF-16: the named §4.3.3 diagnostic, not a tokenizer error
        nobom = joinpath(dir, "utf16_nobom.xml")
        write(nobom, collect(reinterpret(UInt8, u16)))
        @test_throws "UTF-16 without a BOM" read(nobom, Cursor)
    end

    @testset "is_tag compares the name of the current element" begin
        c = Cursor("""<r><ns:a x="1"/>t<é/><?pi d?></r>""")
        next!(c)                                   # <r>
        @test XML.is_tag(c, "r")
        @test !XML.is_tag(c, "rr") && !XML.is_tag(c, "") && !XML.is_tag(c, "R")
        next!(c)                                   # <ns:a>
        @test XML.is_tag(c, "ns:a") && !XML.is_tag(c, "a")
        @test XML.is_tag(c, SubString("xns:a", 2))
        next!(c)                                   # the text
        @test !XML.is_tag(c, "t")
        next!(c)                                   # <é/>
        @test XML.is_tag(c, "é") && !XML.is_tag(c, "e")
        next!(c)                                   # the processing instruction
        @test tag(c) == "pi" && !XML.is_tag(c, "pi")
    end

    @testset "attribute! reads named attributes in one pass" begin
        xml = """<row><c r="B7" s = '3' u="a&amp;b" w="x\ty"><v>42.5</v></c><d r="1" r="2"/><e/></row>"""
        c = Cursor(xml); next!(c); next!(c)        # on <c>
        @test XML.attribute!(c, "r", "t", "s") == ("B7", nothing, "3")
        @test nodetype(c) === Element && tag(c) == "c" && depth(c) == 2
        # a second call reads the tag again, and the values are those of `get`
        @test XML.attribute!(c, "u", "w", "zz") == ("a&b", "x y", nothing)
        @test XML.attribute!(c, "u", "w") == (get(c, "u", nothing), get(c, "w", nothing))
        @test XML.attribute!(c) == ()
        # the walk goes on after the tag
        next!(c); @test tag(c) == "v" && depth(c) == 3
        next!(c); @test nodetype(c) === Text
        next!(c); @test tag(c) == "d" && depth(c) == 2
        @test XML.attribute!(c, "r") == ("1",)     # the first of two attributes of one name
        next!(c); @test tag(c) == "e" && depth(c) == 2      # `<d …/>` has closed itself
        @test XML.attribute!(c, "r") == (nothing,)
        @test next!(c) === nothing

        # after `eachattribute!` has read part of the tag
        c = Cursor("""<a x="1" y="2" z="3"><b/></a>"""); next!(c)
        @test first(eachattribute!(c)) == ("x" => "1")
        @test XML.attribute!(c, "z", "x") == ("3", "1")
        next!(c); @test tag(c) == "b"

        # skip_element! after attribute! has read a tag that closes itself: the element is
        # behind the cursor already, and the walk goes on at the same depth
        c = Cursor("""<r><c a="1"/><d a="2"><e/></d><f/></r>"""); next!(c); next!(c)   # on <c/>
        @test XML.attribute!(c, "a") == ("1",)
        skip_element!(c)
        next!(c); @test (tag(c), depth(c)) == ("d", 2)
        @test XML.attribute!(c, "a") == ("2",)          # `<d>` is still open after its tag
        skip_element!(c)
        next!(c); @test (tag(c), depth(c)) == ("f", 2)
        @test next!(c) === nothing

        # not an element: `nothing` for each name
        c = Cursor("""<?xml version="1.0"?><a/>"""); next!(c)
        @test nodetype(c) === Declaration
        @test XML.attribute!(c, "version") == (nothing,)
        @test get(c, "version", nothing) == "1.0"

        # a tag that `next!` refuses raises the same error, and the walk still refuses it
        err_of(f) = try f(); "no error" catch e; sprint(showerror, e) end
        for bad in ("<a b><c/></a>", "<a b=c/>", "<a b=\"1", "<a \"x\"/>", "<a b=\"1\" c/>", "<a b", "<a")
            c1 = Cursor(bad); next!(c1)
            c2 = Cursor(bad); next!(c2)
            walked = err_of(() -> next!(c1))
            @test startswith(walked, "ArgumentError")
            @test err_of(() -> XML.attribute!(c2, "b")) == walked
            @test err_of(() -> next!(c2)) == walked
        end

        # other string types give the values of `get`
        doc = """<a k="v" m="x&lt;y"/>"""
        for src in (SubString("<z/>" * doc, 5), StringView(Vector{UInt8}(doc)))
            c = Cursor(src); next!(c)
            @test XML.attribute!(c, "k", "m", "n") == ("v", "x<y", nothing)
            @test XML.attribute!(c, "k", "m") == (get(c, "k", nothing), get(c, "m", nothing))
        end
    end

    @testset "simple_value! reads a simple element and leaves the cursor after it" begin
        xml = "<r><a>one</a><b>x &amp; y</b><c><![CDATA[<d>]]></c><e k=\"1\">t</e><f><g/></f><h></h><i/>z</r>"
        c = Cursor(xml); next!(c); next!(c)                 # on <a>
        @test XML.simple_value!(c) == "one"
        @test nodetype(c) === Element && tag(c) == "a" && depth(c) == 2
        next!(c); @test tag(c) == "b" && depth(c) == 2
        @test XML.simple_value!(c) == "x & y"
        next!(c); @test tag(c) == "c"
        @test XML.simple_value!(c) == "<d>"               # a CDATA section
        @test nodetype(c) === Element && tag(c) == "c" && depth(c) == 2
        # not simple: `nothing`, and the cursor has not moved
        next!(c); @test tag(c) == "e"
        @test XML.simple_value!(c) === nothing            # an attribute
        next!(c); @test nodetype(c) === Text && value(c) == "t" && depth(c) == 3
        next!(c); @test tag(c) == "f" && depth(c) == 2
        @test XML.simple_value!(c) === nothing            # a child element
        next!(c); @test tag(c) == "g" && depth(c) == 3
        next!(c); @test tag(c) == "h" && depth(c) == 2
        @test XML.simple_value!(c) === nothing            # no text
        next!(c); @test tag(c) == "i" && depth(c) == 2
        @test XML.simple_value!(c) === nothing            # `<i/>`
        next!(c); @test nodetype(c) === Text && value(c) == "z" && depth(c) == 2
        @test XML.simple_value!(c) === nothing            # not an element
        @test next!(c) === nothing

        # after `attribute!` has read the start tag of an element without attribute
        c = Cursor("<r><a>one</a><b/></r>"); next!(c); next!(c)
        @test XML.attribute!(c, "k") == (nothing,)
        @test XML.simple_value!(c) == "one"
        next!(c); @test tag(c) == "b" && depth(c) == 2

        # On an element that the cursor has left already, simple_value! gives the text again
        # and does not move: after itself and after skip_element!. skip_element! then has
        # nothing more to skip.
        for leave! in (XML.simple_value!, skip_element!)
            c = Cursor("<r><a>one</a><b/><d/></r>"); next!(c); next!(c)
            leave!(c)
            @test XML.simple_value!(c) == "one"
            skip_element!(c)
            next!(c); @test (tag(c), depth(c)) == ("b", 2)
        end

        # other string types
        for src in (SubString("<z/><r><a>x &lt; y</a><b/></r>", 5), StringView(Vector{UInt8}("<r><a>x &lt; y</a><b/></r>")))
            c = Cursor(src); next!(c); next!(c)
            @test XML.simple_value!(c) == "x < y"
            next!(c); @test tag(c) == "b" && depth(c) == 2
        end

        # the end tag is read as `next!` reads it
        err_of(f) = try f(); "no error" catch e; sprint(showerror, e) end
        c = Cursor("<r><a>one</a x></r>"); next!(c); next!(c)
        @test is_simple_value(c) == "one"             # it stops at the name of the end tag
        @test occursin("expected '>'", err_of(() -> XML.simple_value!(c)))
        c = Cursor("<r><a>one</a"); next!(c); next!(c)
        @test occursin("unterminated close tag", err_of(() -> XML.simple_value!(c)))
        c = Cursor("<r><a><![CDATA[x]]></a y>"); next!(c); next!(c)
        @test occursin("expected '>'", err_of(() -> XML.simple_value!(c)))
    end

    # `next!`, `get`, `is_simple_value` and `eachattribute!` read a text, a tag and a simple
    # element from the bytes. The package keeps the readings through the tokens:
    # `_next_token!`, `_get_from_tokens`, `_is_simple_value_tokens`, `_attr_step_tokens`.
    # Both must give the same nodes, the same values and the same errors at the same
    # positions, on every document. A loop over `eachattribute!` must also leave the
    # cursor's stream where the tokens leave it: after each step, and where it raises.
    @testset "the readings from the bytes give what the token stream gives" begin
        @isdefined(ensure_w3c_suite) || include("w3c_suite.jl")
        ensure_w3c_suite()
        token_step(c) = c.done ? nothing : XML._next_token!(c)
        function key_of(s)
            m = try
                match(r"[ \t\r\n]([A-Za-z_:][A-Za-z0-9_:.-]*)[ \t\r\n]*=", s)
            catch
                nothing
            end
            m === nothing ? "id" : String(m.captures[1])
        end
        function observe(s, key, step, getf, simplef)
            obs = String[]
            err = ""
            try
                c = Cursor(s)
                while step(c) !== nothing
                    nt = nodetype(c)
                    line = string(nt, '|', depth(c), '|', something(tag(c), ""), '|')
                    if nt === Element
                        line *= string(something(getf(c, key, nothing), "∅"), '|',
                                       something(getf(c, "zz", nothing), "∅"), '|',
                                       something(simplef(c), "∅"))
                    else
                        line *= something(value(c), "∅")
                    end
                    push!(obs, line)
                end
            catch e
                err = sprint(showerror, e)
            end
            obs, err
        end
        # A walk that reads the attributes of each element by `eachattribute!`: twice, where
        # the cursor stands and then again from the `<`, or once and only the first of them.
        # Nothing else reads the tag before it. The state of the cursor's stream is noted
        # after each step, and where the loop raises; `next!` is then called once more.
        function observe_attributes(s, step, attr_step, whole)
            obs = Any[]
            err = ""
            reading = false
            c = nothing
            try
                c = Cursor(s)
                while step(c) !== nothing
                    push!(obs, (nodetype(c), depth(c), tag(c), c.st.state))
                    nodetype(c) === Element || continue
                    reading = true
                    for _ in 1:(whole ? 2 : 1)
                        it = eachattribute!(c)
                        st = it.start
                        while true
                            r = attr_step(it, st)
                            push!(obs, c.st.state)
                            r === nothing && break
                            push!(obs, r[1])
                            whole || break
                            st = r[2]
                        end
                    end
                    reading = false
                end
            catch e
                err = string(reading ? "in the attributes: " : "", sprint(showerror, e))
                reading && push!(obs, c.st.state,
                                 try next!(c); "no error" catch e2; sprint(showerror, e2) end)
            end
            obs, err
        end
        docs = String[]
        for (dir, _, files) in walkdir(joinpath(W3C_DIR, "xmlconf")), f in files
            endswith(f, ".xml") && push!(docs, String(read(joinpath(dir, f))))
        end
        @test length(docs) > 3000
        # every prefix of some small documents: the end of the input inside each construct
        small = filter(s -> 40 <= ncodeunits(s) <= 300, docs)[1:40]
        for s in small, k in 1:ncodeunits(s)
            push!(docs, String(codeunits(s)[1:k]))
        end
        refused = 0
        differing = String[]
        refused_in_attributes = 0
        differing_attributes = String[]
        for s in docs
            key = key_of(s)
            bytes = observe(s, key, next!, get, is_simple_value)
            tokens = observe(s, key, token_step, XML._get_from_tokens, XML._is_simple_value_tokens)
            isempty(tokens[2]) || (refused += 1)
            bytes == tokens || push!(differing, first(s, 80))
            for whole in (true, false)
                bytes = observe_attributes(s, next!, iterate, whole)
                tokens = observe_attributes(s, token_step, XML._attr_step_tokens, whole)
                startswith(tokens[2], "in the attributes: ") && (refused_in_attributes += 1)
                bytes == tokens || push!(differing_attributes, first(s, 80))
            end
        end
        @test refused > 1000              # the errors are compared too
        @test differing == String[]
        @test refused_in_attributes > 300     # so are the errors that a loop raises
        @test differing_attributes == String[]
    end

    # Calls on the same element compose: whatever two of them do, the walk goes on in the
    # order of the document, inside the element or after it, at the depths of the document.
    @testset "two calls on the same element leave the walk in order" begin
        docs = (
            """<r><c a="1" b="2"/><d k="v">t<e/>u</d><f>one</f><g x="1">two</g>""" *
                """<h><i/><j>x</j></h><k/><l></l>z</r>""",
            """<s><row r="1"><c r="A1" s="1"/><c r="B1"><v>2</v></c></row>""" *
                """<row r="2"><c r="A2"><v>3</v></c></row></s>""",
            "<a><b><![CDATA[x]]></b><c><!--n--></c><d>a&amp;b</d><e/></a>",
        )
        calls = (
            "eachattribute!" => c -> foreach(identity, eachattribute!(c)),
            "first(eachattribute!)" => c -> iterate(eachattribute!(c)),
            "get" => c -> get(c, "a", nothing),
            "attributes" => attributes,
            "keys" => keys,
            "is_simple_value" => is_simple_value,
            "attribute!" => c -> XML.attribute!(c, "a", "r"),
            "simple_value!" => XML.simple_value!,
            "skip_element!" => skip_element!,
            "for_each_child!" => c -> for_each_child!(ch -> nothing, c),
            "nothing" => c -> nothing,
        )
        node(c) = (nodetype(c), tag(c), depth(c))
        out_of_order = String[]
        for doc in docs
            ref = Any[]
            c = Cursor(doc)
            while next!(c) !== nothing
                push!(ref, node(c))
            end
            for i in eachindex(ref), (fname, f) in calls, (gname, g) in calls
                ref[i][1] === Element || continue
                stop = i                           # the last node of the subtree of the element
                while stop < length(ref) && ref[stop + 1][3] > ref[i][3]
                    stop += 1
                end
                c = Cursor(doc)
                foreach(_ -> next!(c), 1:i)
                f(c); g(c)
                rest = Any[]
                while next!(c) !== nothing
                    push!(rest, node(c))
                end
                # After `for_each_child!` the cursor is past the element, and the second
                # call acts on the node that follows: the walk may then resume further on.
                from = fname == "for_each_child!" ? (stop:length(ref)) : (i, stop)
                any(k -> rest == ref[k + 1:end], from) ||
                    push!(out_of_order, "$fname then $gname on <$(ref[i][2])> of $(first(doc, 12))")
            end
        end
        @test out_of_order == String[]
    end
end
