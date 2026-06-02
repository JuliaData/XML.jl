using Test, XML
using XML: Cursor, next!, for_each_child, eof, nodetype, tag, value, attributes, depth,
           Element, Text, CData, Comment, ProcessingInstruction, Declaration, DTD, LazyNode

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
end
