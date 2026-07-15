# Node identity & structural equality (#83) and the `==`/`hash` contract (#55).
# Semantics: `==`/`isequal`/`hash` are structural — same decoded content — for and across
# all readers (Node, LazyNode, FlatNode); positional identity ("same node of the same
# document") is `XML.issamenode`; search-based navigation on `Node` raises an error when
# the argument matches several indistinguishable occurrences rather than silently
# answering for the first one.

const IDENTITY_XML = """<root a="1" b="2"><item x="1">text</item><item x="2"/><leaf/></root>"""

@testset "==/hash contract on Node (#55)" begin
    a = parse(IDENTITY_XML, Node)
    b = parse(IDENTITY_XML, Node)
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)
    @test length(unique([a, b])) == 1
    d = Dict(a => 1)
    d[b] = 2
    @test length(d) == 1
    @test b in Set([a])
end

@testset "hash respects ==-invariances" begin
    # Attribute order is not significant for `==`, so it cannot be for `hash`.
    p = parse("""<t a="1" b="2"/>""", Node)
    q = parse("""<t b="2" a="1"/>""", Node)
    @test p == q
    @test hash(p) == hash(q)

    # Child order IS significant.
    r = parse("<t><x/><y/></t>", Node)
    s = parse("<t><y/><x/></t>", Node)
    @test r != s

    # `==` treats absent (nothing) and empty children/attributes as equivalent; `hash`
    # must honor the same equivalence (constructed vs parsed empty element).
    el_c = Element("t")
    el_p = only(elements(parse("<t/>", Node)))
    @test el_c == el_p
    @test hash(el_c) == hash(el_p)
end

@testset "navigation errors on indistinguishable occurrences" begin
    # Parsed identical siblings are egal (content-based `===` on immutable fields), so a
    # search from the root cannot tell which occurrence the caller meant.
    twins = only(elements(parse("<a><item/><item/><z/></a>", Node)))
    t1 = twins[1]
    @test_throws ErrorException siblings(t1, twins)
    @test_throws ErrorException parent(t1, twins)

    nested = only(elements(parse("<a><b/><c><b/></c></a>", Node)))
    inner_b = nested[2][1]
    @test_throws ErrorException depth(inner_b, nested)

    # Unambiguous nodes keep the current behavior.
    uniq = only(elements(parse("<a><b/><c/></a>", Node)))
    @test depth(uniq[1], uniq) == 1
    @test length(siblings(uniq[1], uniq)) == 1
    @test parent(uniq[1], uniq) == uniq
end

@testset "FlatNode and LazyNode are structural; identity is issamenode" begin
    s2 = """<a x="1"><b>t</b><b>t</b></a>"""

    f1, f2 = parse(s2, FlatNode), parse(s2, FlatNode)
    @test f1 == f2
    @test hash(f1) == hash(f2)

    l1, l2 = parse(s2, LazyNode), parse(s2, LazyNode)
    @test l1 == l2
    @test hash(l1) == hash(l2)

    # Twins inside one document: structurally equal, positionally distinct.
    fb1, fb2 = elements(only(elements(f1)))
    @test fb1 == fb2
    @test XML.issamenode(fb1, fb1)
    @test !XML.issamenode(fb1, fb2)

    lb1, lb2 = elements(only(elements(l1)))
    @test lb1 == lb2
    @test XML.issamenode(lb1, lb1)
    @test !XML.issamenode(lb1, lb2)
end

@testset "cross-reader structural equality" begin
    n = parse(IDENTITY_XML, Node)
    l = parse(IDENTITY_XML, LazyNode)
    f = parse(IDENTITY_XML, FlatNode)
    @test n == l
    @test n == f
    @test l == f
    @test hash(n) == hash(l) == hash(f)
end
