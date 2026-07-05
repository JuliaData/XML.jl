# FlatNode — the read-only columnar reader: decoded equivalence with Node, accessor
# surface, positional identity, well-formedness parity with the Node parser.

# Recursive decoded comparison: FlatNode must agree with Node{String} on kind, tag,
# decoded value, decoded attributes, and tree shape.
function flat_agrees_with_node(a, b)
    nodetype(a) === nodetype(b) || return false
    isequal(tag(a), tag(b)) || return false
    isequal(value(a), value(b)) || return false
    aa, ba = attributes(a), attributes(b)
    (aa === nothing) === (ba === nothing) || return false
    if aa !== nothing
        [String(k) => String(v) for (k, v) in aa] == [String(k) => String(v) for (k, v) in ba] || return false
    end
    ca, cb = children(a), children(b)
    length(ca) == length(cb) || return false
    all(flat_agrees_with_node(x, y) for (x, y) in zip(ca, cb))
end

const RICH_XML = """<?xml version="1.0"?><!DOCTYPE root [<!ENTITY x "y">]>
<!-- top comment -->
<root a="1" b="two &amp; three">
  <item>plain</item>
  <item attr="v&lt;w">enti&amp;ty</item>
  <empty/>
  <![CDATA[raw &amp; cdata]]>
  <?pi target content?>
  mixed text &#65;
</root>"""

@testset "decoded equivalence with Node" begin
    f = parse(RICH_XML, FlatNode)
    n = parse(RICH_XML, Node)
    @test flat_agrees_with_node(f, n)
    @test XML.write(f) == XML.write(n)

    path = joinpath(@__DIR__, "data", "books.xml")
    if isfile(path)
        @test flat_agrees_with_node(read(path, FlatNode), read(path, Node))
    end
end

@testset "accessor surface" begin
    f = parse(RICH_XML, FlatNode)
    n = parse(RICH_XML, Node)
    root  = only(eachelement(f))
    rootn = only(eachelement(n))

    @test nodetype(f) === XML.Document && nodetype(root) === XML.Element
    @test tag(root) == "root"
    @test length(root) == length(children(rootn))
    @test attributes(root) == ["a" => "1", "b" => "two & three"]   # decoded at access

    els = collect(eachelement(root))
    @test [tag(e) for e in els] == ["item", "item", "empty"]
    @test value(children(els[2])[1]) == "enti&ty"                   # decoded at access
    @test attributes(els[2]) == ["attr" => "v<w"]
    @test children(children(els[1])[1]) == ()                       # Text leaf: no children
    @test attributes(els[3]) === nothing                            # <empty/>: no attributes

    # parent is O(1) and defined; depth counts from the Document node
    @test parent(f) === nothing
    @test parent(root) == f && parent(els[1]) == root
    @test depth(f) == 1 && depth(root) == 2 && depth(els[1]) == 3

    # indexing walks children (whitespace Text nodes included, as everywhere in v0.4)
    @test root[2] == els[1]
    @test_throws BoundsError root[length(root) + 1]

    # is_simple/simple_value parity with Node
    elsn = filter(c -> nodetype(c) === XML.Element, children(rootn))
    @test [is_simple(e) for e in els] == [is_simple(e) for e in elsn]
    @test simple_value(els[1]) == simple_value(elsn[1]) == "plain"

    @test occursin("Element", repr(root))                           # show smoke
end

@testset "positional identity (== and hash)" begin
    f = parse(RICH_XML, FlatNode)
    root = only(eachelement(f))
    els = collect(eachelement(root))
    @test els[1] == els[1] && els[1] != els[2]
    @test hash(els[1]) != hash(els[2])
    @test length(unique([els[1], els[1], els[2]])) == 2             # the #55 behavior, fixed here
    # two parses of the same document are DIFFERENT stores: handles compare unequal;
    # compare content by materializing.
    f2 = parse(RICH_XML, FlatNode)
    @test f != f2
    @test Node(f) == Node(f2)
end

@testset "Node materialization" begin
    f = parse(RICH_XML, FlatNode)
    n = parse(RICH_XML, Node)
    @test Node(f) == n
    els  = collect(eachelement(only(eachelement(f))))
    elsn = filter(c -> nodetype(c) === XML.Element, children(only(eachelement(n))))
    @test Node(els[2]) == elsn[2]
end

@testset "well-formedness parity with the Node parser" begin
    cases = [
        ("<a><b></a>",        NamedTuple()),                # mismatched tags (ungated)
        ("</a>",              NamedTuple()),                # close without open (ungated)
        ("<a>",               NamedTuple()),                # unclosed tag (ungated)
        ("<a x=\"1\" x=\"2\"/>", NamedTuple()),             # duplicate attribute (ungated)
        ("<a/><b/>",          NamedTuple()),                # multiple roots (:structural)
        ("top<a/>",           NamedTuple()),                # top-level text (:structural)
        ("<a b=\"c<d\"/>",    NamedTuple()),                # '<' in attribute (:structural)
        ("<1a/>",             NamedTuple()),                # invalid name start (:structural)
        ("<a>&#0;</a>",       (wellformed = :strict,)),     # illegal charref (:strict)
        ("<a><!-- x-- --></a>", (wellformed = :strict,)),   # "--" in comment (:strict)
    ]
    for (bad, kw) in cases
        err_node = try parse(bad, Node; kw...); nothing catch e sprint(showerror, e) end
        err_flat = try parse(bad, FlatNode; kw...); nothing catch e sprint(showerror, e) end
        @test err_node !== nothing
        @test err_node == err_flat
    end
    # :lenient accepts what Node's :lenient accepts
    @test parse("<a/><b/>", FlatNode; wellformed = :lenient) isa FlatNode
    @test XML.write(parse("<a/><b/>", FlatNode; wellformed = :lenient)) ==
          XML.write(parse("<a/><b/>", Node;     wellformed = :lenient))
end

@testset "BOM handling" begin
    bom = "﻿<r>x</r>"
    @test flat_agrees_with_node(parse(bom, FlatNode), parse(bom, Node))
    utf8_bom = vcat([0xEF, 0xBB, 0xBF], Vector{UInt8}("<r>x</r>"))
    @test simple_value(only(eachelement(read(IOBuffer(utf8_bom), FlatNode)))) == "x"
    utf16le = vcat([0xFF, 0xFE], reinterpret(UInt8, Vector{UInt16}(transcode(UInt16, "<r>x</r>"))))
    @test simple_value(only(eachelement(read(IOBuffer(utf16le), FlatNode)))) == "x"
end
