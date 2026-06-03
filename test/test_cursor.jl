using Test, XML
using XML: Cursor, next!, for_each_child, @for_each_child, skip_element!, eof, nodetype,
           tag, value, attributes, depth, children, Element, Text, CData, Comment,
           ProcessingInstruction, Declaration, DTD, LazyNode

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

    @testset "for_each_child yields immediate children only" begin
        doc = """<r><a><deep/></a><c/><e/></r>"""
        c = parse(Cursor, doc)
        next!(c)                            # position at <r>
        @test String(tag(c)) == "r"
        kids = String[]
        for_each_child(c) do ch
            push!(kids, String(tag(ch)))
        end
        @test kids == ["a", "c", "e"]       # <deep> is a grandchild, excluded
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

    @testset "nested for_each_child composes (DFS), incl. minified" begin
        # Regression: a consume-on-break for_each_child skipped the *second* subtree of
        # a parent when there was no inter-element whitespace to buffer the boundary node
        # (the boundary node was consumed by the enclosing sweep's next!). The peekable
        # `held` flag holds the boundary node so composition is correct for any input.
        function folders(doc)
            c = parse(Cursor, doc); next!(c)        # position at <Document>
            out = Tuple{String,Vector{String}}[]
            for_each_child(c) do _
                nodetype(c) === Element || return
                ftag = String(tag(c))               # capture before descending (aliasing contract)
                kids = String[]
                for_each_child(c) do _
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
        for_each_child(c) do _               # F
            nodetype(c) === Element || return
            for_each_child(c) do _           # P
                nodetype(c) === Element || return
                ptag = String(tag(c)); ks = String[]
                for_each_child(c) do _
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
        c = Cursor(doc, apos)
        @test next!(c) !== nothing
        @test String(tag(c)) == "a"
        @test depth(c) == 1
        kids = String[]
        @for_each_child c ch begin
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
        @for_each_child c2 ch begin
            nodetype(ch) === Element && push!(kids2, String(tag(ch)))
        end
        @test kids2 == ["x", "y"]
    end

    @testset "@for_each_child inlines (accumulates locals without a closure)" begin
        # The macro body assigns enclosing locals directly — the case a do-block
        # would box. Verify correctness of such accumulation, nested + minified.
        doc = "<D><F><P><name>A</name><Point/></P><P><name>B</name></P></F></D>"
        c = parse(Cursor, doc); next!(c)              # at <D>
        placemarks = Tuple{Int,Bool}[]                # (child_element_count, saw_name)
        @for_each_child c f begin                     # F
            nodetype(f) === Element || continue
            @for_each_child c p begin                 # P
                nodetype(p) === Element || continue
                n = 0; saw_name = false               # locals mutated inside the inner macro body
                @for_each_child c g begin
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
        # skip_element! must leave the cursor exactly where for_each_child's full walk
        # would on the next sibling — but without tokenizing the skipped subtree, even
        # when it contains a literal </tag> inside CDATA/comments or a > inside an attr.
        kids_plain(doc) = begin
            c = parse(Cursor, doc); next!(c); t = String[]
            for_each_child(c) do _
                nodetype(c) === Element && push!(t, String(tag(c)))
            end
            t
        end
        kids_skip(doc) = begin
            c = parse(Cursor, doc); next!(c); t = String[]
            for_each_child(c) do _
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
            ("""<r><a x="1>2"><y/></a><b/></r>""",             ["a", "b"]),     # > inside attr value
            ("<r><a><a><a/></a></a><b/></r>",                  ["a", "b"]),     # nested same name
            ("<r><a><?pi <x> ?></a><b/></r>",                  ["a", "b"]),     # markup-ish PI body
            ("<D><F><P><name>n</name></P></F><F><P/></F></D>", ["F", "F"]),     # minified
        ]
        for (doc, exp) in cases
            @test kids_plain(doc) == exp
            @test kids_skip(doc) == exp
        end
    end
end
