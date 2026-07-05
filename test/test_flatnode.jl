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

    # Empty content is a VALUE ("" — value_offset ≥ 0), distinct from no value (nothing,
    # value_offset == -1). Caught by W3C parity (sun/invalid/empty.xml, oasis p15/p18).
    empties = "<r x=\"\"><!----><![CDATA[]]><?pi?></r>"
    fe, ne = parse(empties, FlatNode), parse(empties, Node)
    @test flat_agrees_with_node(fe, ne)
    rootels = children(only(eachelement(fe)))
    @test value(rootels[1]) == "" && nodetype(rootels[1]) === XML.Comment
    @test value(rootels[2]) == "" && nodetype(rootels[2]) === XML.CData
    @test value(rootels[3]) === nothing && nodetype(rootels[3]) === XML.ProcessingInstruction
    @test attributes(only(eachelement(fe))) == ["x" => ""]
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

    # is_simple/simple_value/is_simple_value parity with Node
    elsn = filter(c -> nodetype(c) === XML.Element, children(rootn))
    @test [is_simple(e) for e in els] == [is_simple(e) for e in elsn]
    @test simple_value(els[1]) == simple_value(elsn[1]) == "plain"
    @test [is_simple_value(e) for e in els] == [is_simple_value(e) for e in elsn]

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

@testset "sourcetext (source spans)" begin
    xml = """<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x "y">]><!-- c --><r a="1">
  <item>plain</item><![CDATA[cd]]><?pi tgt?><!----><empty/><sp ></sp >
</r>"""
    f  = parse(xml, FlatNode; wellformed = :lenient)
    lz = parse(xml, LazyNode)

    # exact-slice parity with LazyNode's sourcetext, top-level and inside the root
    for (a, b) in zip(children(f), children(lz))
        @test isequal(sourcetext(a), sourcetext(b))
    end
    root = only(eachelement(f))
    rootlz = first(Iterators.filter(c -> nodetype(c) === XML.Element, children(lz)))
    for (a, b) in zip(children(root), children(rootlz))
        @test isequal(sourcetext(a), sourcetext(b))
    end

    @test sourcetext(f) == xml                                   # Document = whole source
    it = first(eachelement(root))
    @test sourcetext(it) == "<item>plain</item>"
    # re-parsing an element's slice reproduces the subtree
    @test Node(only(eachelement(parse(String(sourcetext(it)), FlatNode; wellformed = :lenient)))) == Node(it)
end

@testset "BOM handling" begin
    bom = "﻿<r>x</r>"
    @test flat_agrees_with_node(parse(bom, FlatNode), parse(bom, Node))
    utf8_bom = vcat([0xEF, 0xBB, 0xBF], Vector{UInt8}("<r>x</r>"))
    @test simple_value(only(eachelement(read(IOBuffer(utf8_bom), FlatNode)))) == "x"
    utf16le = vcat([0xFF, 0xFE], reinterpret(UInt8, Vector{UInt16}(transcode(UInt16, "<r>x</r>"))))
    @test simple_value(only(eachelement(read(IOBuffer(utf16le), FlatNode)))) == "x"
end

# W3C conformance parity: FlatNode must agree with the Node parser on every document of
# the pinned suite — decoded-equivalent trees on the well-formed corpus, and the exact
# same accept/reject verdict on the not-well-formed corpus. (`valid_tests`/`notwf_tests`
# are globals from test_w3c.jl, which runs earlier in the suite; guard for standalone runs.)
if @isdefined(valid_tests)
    @testset "W3C parity with the Node parser" begin
        n_cmp = 0
        for test in valid_tests
            isfile(test.uri) || continue
            n = try read(test.uri, Node; wellformed = :strict) catch; continue end
            f = read(test.uri, FlatNode; wellformed = :strict)
            @test flat_agrees_with_node(f, n)
            n_cmp += 1
        end
        @info "W3C valid: FlatNode ≡ Node on $n_cmp documents"

        n_agree = 0
        disagreements = String[]
        for test in notwf_tests
            isfile(test.uri) || continue
            rejects_node = try read(test.uri, Node; wellformed = :strict); false catch; true end
            rejects_flat = try read(test.uri, FlatNode; wellformed = :strict); false catch; true end
            rejects_node == rejects_flat ? (n_agree += 1) : push!(disagreements, test.id)
        end
        isempty(disagreements) || @warn "verdict disagreements" disagreements=first(disagreements, 20)
        @test isempty(disagreements)
        @info "W3C not-wf: identical verdicts on $n_agree documents"
    end
end
