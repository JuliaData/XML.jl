import AbstractTrees

@testset "AbstractTrees extension" begin
    xml = """
    <?xml version="1.0"?>
    <!-- top -->
    <library>
      <book id="1">
        <title>One</title>
        <author>Alice</author>
      </book>
      <book id="2">
        <title>Two</title>
      </book>
    </library>
    """

    @testset "extension is loaded" begin
        @test Base.get_extension(XML, :XMLAbstractTreesExt) !== nothing
    end

    @testset "children (Node)" begin
        doc = parse(xml, Node)
        @test AbstractTrees.children(doc) == XML.children(doc)
        lib = first(filter(c -> nodetype(c) == Element, XML.children(doc)))
        @test AbstractTrees.children(lib) == XML.children(lib)

        title = first(filter(c -> nodetype(c) == Element, XML.children(lib)))[1]
        # `<title>One</title>` — title element's only child is a Text node with no children
        @test isempty(AbstractTrees.children(title))
    end

    @testset "children (LazyNode)" begin
        ldoc = parse(xml, LazyNode)
        @test length(AbstractTrees.children(ldoc)) == length(XML.children(ldoc))
        lib = first(filter(c -> nodetype(c) == Element, XML.children(ldoc)))
        @test length(AbstractTrees.children(lib)) == length(XML.children(lib))
    end

    @testset "nodevalue identity" begin
        doc = parse(xml, Node)
        @test AbstractTrees.nodevalue(doc) === doc
        ldoc = parse(xml, LazyNode)
        @test AbstractTrees.nodevalue(ldoc) === ldoc
    end

    @testset "traits" begin
        @test AbstractTrees.NodeType(Node) === AbstractTrees.HasNodeType()
        @test AbstractTrees.NodeType(LazyNode) === AbstractTrees.HasNodeType()
        @test AbstractTrees.nodetype(Node{String}) === Node{String}
        @test AbstractTrees.ChildIndexing(Node) === AbstractTrees.IndexedChildren()
    end

    @testset "PreOrderDFS visits every node" begin
        doc = parse(xml, Node)
        elements = [n for n in AbstractTrees.PreOrderDFS(doc) if nodetype(n) == Element]
        @test map(tag, elements) == ["library", "book", "title", "author", "book", "title"]

        ldoc = parse(xml, LazyNode)
        lelements = [n for n in AbstractTrees.PreOrderDFS(ldoc) if nodetype(n) == Element]
        @test map(tag, lelements) == ["library", "book", "title", "author", "book", "title"]
    end

    @testset "printnode labels" begin
        @test sprint(AbstractTrees.printnode, Element("div", "hi"; class="main")) == "<div class=\"main\">"
        @test sprint(AbstractTrees.printnode, Text("hello")) == "\"hello\""
        @test sprint(AbstractTrees.printnode, Comment("c")) == "<!--c-->"
        @test sprint(AbstractTrees.printnode, CData("xyz")) == "<![CDATA[xyz]]>"
        @test sprint(AbstractTrees.printnode, DTD("note")) == "<!DOCTYPE note>"
        @test sprint(AbstractTrees.printnode, ProcessingInstruction("xml-stylesheet", "type=\"text/xsl\"")) ==
            "<?xml-stylesheet type=\"text/xsl\"?>"
        @test sprint(AbstractTrees.printnode, Declaration(version="1.0")) == "<?xml version=\"1.0\"?>"
        @test sprint(AbstractTrees.printnode, Document()) == "Document"

        ldoc = parse("<a x=\"1\"><b>hi</b></a>", LazyNode)
        a = ldoc[1]
        @test sprint(AbstractTrees.printnode, a) == "<a x=\"1\">"
    end

    @testset "print_tree round-trips structure" begin
        doc = parse("<a><b/><c><d/></c></a>", Node)
        out = sprint(AbstractTrees.print_tree, doc)
        @test occursin("Document", out)
        @test occursin("<a>", out)
        @test occursin("<b>", out)
        @test occursin("<c>", out)
        @test occursin("<d>", out)
    end
end
