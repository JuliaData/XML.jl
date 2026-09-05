# Decoded read surface — allocation guards. A union-typed return that crosses a
# non-inlined call boundary heap-boxes every call (32 B); in per-cell hot loops
# (spreadsheet-style attribute sweeps) that box dominates the accessor's real work
# (#98, #104, #105). Every guard measures inside a function barrier — the call, not the
# caller's dynamically-typed scope — and consumes the value in place, so a boxed return
# cannot hide behind the measuring boundary.

using Test, XML
using XML: unescape
using Mmap, StringViews

# The value-correctness checks always run (they double as compile warm-up for each
# barrier); the `== 0` assertions are skipped under coverage, whose counters allocate
# inside the measured call (same gate as the `_normalize_attr_ws` guard in runtests.jl).
const _NO_COVERAGE = Base.JLOptions().code_coverage == 0

# `Node`'s by-key attribute lookups return through a union boundary that the 1.10 and
# 1.11 inliners do not flatten, so each call re-boxes (32 B) there under either bounds
# flag — measured identically on v0.4.4 and v0.4.5, a compiler-generation limit rather
# than a package regression; 1.12 returns it unboxed and holds the zero guard.
const _ND_BYKEY_CEILING = VERSION < v"1.12" ? 32 : 0

_use(v) = v === nothing ? 0 : ncodeunits(v)

measure_get(x)       = @allocated _use(get(x, "r", nothing))
measure_index(x)     = @allocated _use(x["r"])
measure_haskey(x)    = @allocated haskey(x, "r")
measure_tag(x)       = @allocated _use(tag(x))
measure_unescape(x)  = @allocations _use(unescape(x))
measure_value(x)     = @allocated _use(value(x))
measure_simple(x)    = @allocated _use(simple_value(x))
measure_is_simple(x) = @allocated _use(is_simple_value(x))
function measure_eachattr(x)
    @allocated begin
        s = 0
        for (k, v) in eachattribute(x)
            s += ncodeunits(k) + ncodeunits(v)
        end
        s
    end
end

@testset "Decoded read surface: allocation-free" begin
    attr_xml   = """<c r="A1" s="3" t="str"/>"""
    simple_xml = "<a>hello</a>"

    lz = only(eachelement(parse(attr_xml, LazyNode)))
    fl = only(eachelement(parse(attr_xml, FlatNode)))
    nd = only(eachelement(parse(attr_xml, Node)))
    cu = parse(Cursor, attr_xml); next!(cu)                 # positioned on <c>

    slz = only(eachelement(parse(simple_xml, LazyNode)))
    sfl = only(eachelement(parse(simple_xml, FlatNode)))
    snd = only(eachelement(parse(simple_xml, Node)))
    scu = parse(Cursor, simple_xml); next!(scu)             # positioned on <a>

    tlz = only(children(slz))
    tfl = only(children(sfl))
    tnd = only(children(snd))
    tcu = parse(Cursor, simple_xml); next!(tcu); next!(tcu) # positioned on the Text node

    @testset "the shared decode root is type-stable" begin
        @test only(Base.return_types(unescape, (SubString{String},))) === SubString{String}
    end

    # `unescape` on a value that carries a reference allocates once, the result string
    # itself (#141). The ceiling is a count rather than bytes: the result's size is the value's.
    @testset "unescape allocates once per decoded value" begin
        str = "a &amp; b &#x41; &#65; &lt; c"
        sub = SubString(str)
        @test unescape(sub) == "a & b A A < c"
        @test unescape(str) == "a & b A A < c"
        measure_unescape(sub); measure_unescape(str)
        if _NO_COVERAGE
            @test measure_unescape(sub) <= 1
            @test measure_unescape(str) <= 1
        end
        mktemp() do path, io
            write(io, str)
            close(io)
            open(path) do f
                sv = StringView(Mmap.mmap(f))
                @test unescape(sv) == "a & b A A < c"
                measure_unescape(sv)
                _NO_COVERAGE && @test measure_unescape(sv) <= 1
            end
        end
    end

    @testset "guarded fixtures read correctly" begin
        for x in (lz, fl, cu, nd)
            @test get(x, "r", nothing) == "A1"
            @test get(x, "nope", nothing) === nothing
            @test x["r"] == "A1"
            @test_throws KeyError x["nope"]
            @test haskey(x, "r") && !haskey(x, "nope")
            @test tag(x) == "c"
        end
        @test collect(eachattribute(lz)) == ["r" => "A1", "s" => "3", "t" => "str"]
        for x in (tlz, tfl, tcu, tnd)
            @test value(x) == "hello"
        end
        for x in (slz, sfl, snd)
            @test simple_value(x) == "hello"
        end
        for x in (slz, sfl, scu, snd)
            @test is_simple_value(x) == "hello"
        end
    end

    # compile every barrier specialization before measuring
    for x in (lz, fl, cu, nd)
        measure_get(x); measure_index(x); measure_haskey(x); measure_tag(x)
    end
    measure_eachattr(lz)
    foreach(measure_value, (tlz, tfl, tcu, tnd))
    foreach(measure_simple, (slz, sfl, snd))
    foreach(measure_is_simple, (slz, sfl, scu, snd))

    if _NO_COVERAGE
        @testset "by-key attribute reads" begin
            @test measure_get(lz) == 0
            @test measure_get(fl) == 0
            @test measure_get(cu) == 0
            @test measure_get(nd) <= _ND_BYKEY_CEILING
            @test measure_index(lz) == 0
            @test measure_index(fl) == 0
            @test measure_index(cu) == 0
            @test measure_index(nd) <= _ND_BYKEY_CEILING
            @test measure_haskey(lz) == 0
            @test measure_haskey(fl) == 0
            @test measure_haskey(cu) == 0
            @test measure_haskey(nd) <= _ND_BYKEY_CEILING
        end

        @testset "tag" begin
            @test measure_tag(lz) == 0
            @test measure_tag(fl) == 0
            @test measure_tag(cu) == 0
            @test measure_tag(nd) == 0
        end

        @testset "value on a Text node" begin
            @test measure_value(tlz) == 0
            @test measure_value(tfl) == 0
            @test measure_value(tcu) == 0
            @test measure_value(tnd) == 0
        end

        @testset "simple_value / is_simple_value" begin
            @test measure_simple(slz) == 0
            @test measure_simple(sfl) == 0
            @test measure_simple(snd) == 0
            @test measure_is_simple(slz) == 0
            @test measure_is_simple(sfl) == 0
            @test measure_is_simple(scu) == 0
            @test measure_is_simple(snd) == 0
        end

        @testset "eachattribute streams without allocating" begin
            @test measure_eachattr(lz) == 0
        end
    end
end

# Lazy child iteration — the iteration protocol must not allocate: pulling any number of
# children through an already-created iterator is 0 B (no per-step tuple boxing, no heap
# cursor cell, no per-call tokenizer wrapper). Creating an iterator costs one small
# mutable object — its shared, resumable cursor, the semantics downstream row streams
# (XLSX.jl) depend on — and escape analysis elides it when the iterator dies without
# looping, so a recursive traversal allocates at most one object per container node.
function walk_count(n)
    c = 1
    for ch in XML.eachchildnode(n)
        c += walk_count(ch)
    end
    c
end
measure_walk(n) = @allocated walk_count(n)

function element_count(n)
    c = 0
    for el in eachelement(n)
        c += 1 + element_count(el)
    end
    c
end
measure_elements(n) = @allocated element_count(n)

function consume_count(it)
    c = 0
    for _ in it
        c += 1
    end
    c
end
measure_consume(it) = @allocated consume_count(it)
measure_mk_child(n) = @allocated XML.eachchildnode(n)

@testset "Lazy iteration: allocation-light traversal" begin
    torture_xml = """<?xml version="1.0"?><!-- top --><r a="1">t1<e1 x="y"><in>deep</in><self/></e1><!-- c --><![CDATA[cd]]><?pi d?><e2>café</e2>tail</r>"""
    doc = parse(torture_xml, LazyNode)
    attr_el = only(eachelement(parse("""<e x="1" y="2" z="3"/>""", LazyNode)))

    @testset "traversal reads correctly" begin
        @test walk_count(doc) == 15       # doubles as compile warm-up
        @test element_count(doc) == 5
        @test consume_count(XML.eachchildnode(doc)) == 3
        @test consume_count(eachattribute(attr_el)) == 3
        measure_mk_child(doc)             # warm-up for the creation guard
    end

    if _NO_COVERAGE
        @testset "consuming a pre-built iterator is free" begin
            @test measure_consume(XML.eachchildnode(doc)) == 0
            @test measure_consume(eachelement(doc)) == 0
            @test measure_consume(eachattribute(attr_el)) == 0
        end
        @testset "iterator creation is one small object" begin
            @test measure_mk_child(doc) <= 96
        end
        @testset "recursive traversal: at most one object per container node" begin
            # 6 containers here (the document + 5 elements); ceilings hold even if a
            # future compiler elides more of them.
            @test measure_walk(doc) <= 6 * 96
            @test measure_elements(doc) <= 6 * 96
        end
    end
end

# Node build — the scratch-stack contract: children and attributes accumulate on
# parse-wide stacks, sliced out exact-size at each closing tag (no per-element vector
# churn). 400 one-attribute one-text elements cost ~4.0 K allocations today; a churn
# regression re-adds at least two vectors per element (≥ +800), so the ceiling sits
# between the two, wide enough for version-to-version noise.
measure_node_build_allocs(xml) = Base.@allocations parse(xml, Node)

@testset "Node build: scratch-stack allocation ceiling" begin
    churn_xml = "<root>" * repeat("<e a=\"1\">t</e>", 400) * "</root>"
    @test length(children(only(children(parse(churn_xml, Node))))) == 400
    measure_node_build_allocs(churn_xml)   # warm-up
    if _NO_COVERAGE
        @test measure_node_build_allocs(churn_xml) <= 4500
    end
end

# Line-end rewrite — the sizing contract: the output is bounded by its source (a CR LF pair
# loses a byte, a lone CR keeps its own), so one buffer is allocated at that bound and shrunk
# to what was written. A short value costs three objects on 1.12 and two on 1.10; the
# same rewrite through a growable stream costs four on both, so a ceiling of three
# separates the two shapes at every supported version.
measure_eol_rewrite(s) = Base.@allocations XML._rewrite_content_eol(s)

@testset "Line-end rewrite: one buffer, sized on the source" begin
    v = "        \r\n"
    @test XML._rewrite_content_eol(v) == "        \n"
    @test XML._rewrite_content_eol("a\rb\r\nc") == "a\nb\nc"
    measure_eol_rewrite(v)   # warm-up
    if _NO_COVERAGE
        @test measure_eol_rewrite(v) <= 3
    end
end

# `:strict` reference check — the contract: on a token that carries a `&`, the check reads the
# code units and copies nothing on a span it accepts, so the level allocates exactly what
# `:structural` allocates on a document full of references. The direct guard holds the check
# to zero; the parse-level one holds `:strict` to the count of `:structural`, the acceptance
# line of section (8) of `benchmarks/profile.jl`, and covers the character-range scan too.
measure_refcheck(s, names)    = Base.@allocations XML._check_refs_strict(s, names)
measure_parse_strict(xml)     = Base.@allocations parse(xml, Node; wellformed = :strict)
measure_parse_structural(xml) = Base.@allocations parse(xml, Node; wellformed = :structural)

@testset ":strict reference check: allocation-free on an accepted span" begin
    span = "a &amp; b &#65; c &#x42; d &quot;&apos;&lt;&gt; e &#x1F600;"
    sub = SubString("<" * span * ">", 2, ncodeunits(span) + 1)
    @test XML._check_refs_strict(sub, true) === nothing
    @test XML._check_refs_strict(span, false) === nothing
    refs_xml = "<root>" * repeat("<e a=\"&amp;&#65;\">x &lt; &#x42; &quot;y&quot;</e>", 200) * "</root>"
    doc = parse(refs_xml, Node; wellformed = :strict)
    @test length(children(only(children(doc)))) == 200
    @test doc == parse(refs_xml, Node; wellformed = :structural)
    measure_refcheck(sub, true); measure_refcheck(span, false)               # warm-up
    measure_parse_strict(refs_xml); measure_parse_structural(refs_xml)
    if _NO_COVERAGE
        @test measure_refcheck(sub, true) == 0
        @test measure_refcheck(span, false) == 0
        @test measure_parse_strict(refs_xml) == measure_parse_structural(refs_xml)
    end
end
