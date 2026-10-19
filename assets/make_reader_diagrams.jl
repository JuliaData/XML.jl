# Draws the three diagrams of READERS.md, which show how `Node`, `FlatNode` and `LazyNode` hold the
# document <rr a="1">hi<c/></rr>, and checks the allocation counts that page quotes.
#
#   julia --project=assets assets/make_reader_diagrams.jl
#
# Every count drawn or quoted is first measured on the package with BenchmarkTools, and a mismatch
# stops the script: it never redraws a count the code no longer gives. Nothing else checks READERS.md,
# so run the script again after changing a reader and before each release. The counts are those of
# Julia 1.13; under Julia 1.10, where a vector is one allocation and not two, they differ.
#
# Graphviz's `dot` places the boxes. A few arrows are then redrawn as explicit Bézier paths, and
# `neato -n2` renders that fixed layout as SVG. The cairo renderer draws the text as outlines, so the
# result does not depend on the fonts of the viewer.
using XML, BenchmarkTools, Graphviz_jll
using XML: nodetype, tag, value, attributes, children

include(joinpath(@__DIR__, "..", "benchmarks", "XMarkGenerator.jl"))
using .XMarkGenerator

const OUT = @__DIR__
const XMLDOC = "<rr a=\"1\">hi<c/></rr>"

#-----------------------------------------------------------------------------# counts
# Concrete types in small functions: a type passed in a variable makes the call dynamic, and boxing
# its result adds one allocation.
pnode(s) = parse(s, Node)
pflat(s) = parse(s, FlatNode)
plazy(s) = parse(s, LazyNode)
allocs(f, x) = (@benchmark $f($x) samples = 1 evals = 1).allocs

# What `Node` keeps for each node, read through the public accessors.
function fullread(n)
    s = Int(nodetype(n) === XML.Element)
    t = tag(n);        t === nothing || (s += ncodeunits(t))
    v = value(n);      v === nothing || (s += ncodeunits(v))
    a = attributes(n); a === nothing || (s += length(a))
    for c in children(n)
        s += fullread(c)
    end
    s
end
# A plain loop: `children` returns `()` or a vector, and a generator over that union allocates itself.
function walk(n)
    s = 1
    for c in children(n)
        s += walk(c)
    end
    s
end

function check(what, got, want)
    got == want || error("$what: $got, but the diagrams or READERS.md say $want; update them")
    println(rpad(what, 62), got)
end

println("Julia ", VERSION, " · XML ", pkgversion(XML))
let r = only(children(plazy(XMLDOC)))
    check("parse(xml, Node), allocations", allocs(pnode, XMLDOC), 25)
    check("parse(xml, FlatNode), allocations", allocs(pflat, XMLDOC), 17)
    check("parse(xml, LazyNode), allocations", allocs(plazy, XMLDOC), 0)
    check("children(r) on LazyNode, allocations", allocs(children, r), 3)
end
for (T, p, want) in ((Node, pnode, 0), (FlatNode, pflat, 7), (LazyNode, plazy, 12))
    check("reading every node with $T, allocations after parse", allocs(fullread, p(XMLDOC)), want)
end
check("walking with children alone on LazyNode, allocations", allocs(walk, plazy(XMLDOC)), 8)
let xmark = generate_xmark(1.0)   # the 14 MB document of the README
    nn = walk(pnode(xmark))
    check("14 MB document, nodes", nn, 882_026)
    check("14 MB document, parse(xml, FlatNode) allocations", allocs(pflat, xmark), 40)
    for (T, p, want) in ((Node, pnode, 2.86), (FlatNode, pflat, 0.88), (LazyNode, plazy, 1.59))
        per = round((allocs(p, xmark) + allocs(fullread, p(xmark))) / nn; digits = 2)
        check("14 MB document, $T: parse + read, allocations per node", per, want)
    end
end

#-----------------------------------------------------------------------------# drawing
const SRCFILL = "#FFF6D6"   # the source string
const COVFILL = "#FCE3CC"   # bytes designated by a position and a length
const OBJFILL = "#EAF2FB"   # objects and handles
const TABFILL = "#F2F2F2"   # arrays
const TMPFILL = "#FFFFFF"   # temporary allocations (dashed frame)
const READFILL = "#F2C4C4"  # bytes a call reads again (bars under the source)
const POS = "#D9822B"       # arrow: a position in the source
const REF = "#555555"       # arrow: a reference
const EXAMPLE = "&lt;rr a=&quot;1&quot;&gt;hi&lt;c/&gt;&lt;/rr&gt;"

hesc(c) = c == '<' ? "&lt;" : c == '>' ? "&gt;" : c == '"' ? "&quot;" : c == '&' ? "&amp;" :
          c == ' ' ? "<FONT COLOR=\"#999999\">·</FONT>" : string(c)

# The source, designated bytes shaded, byte positions under the characters (ports `bN` and `iN`).
# `bars`: (label, first byte, last byte), one bar per call that reads those bytes again.
function source_node(covered; bars = ())
    n = ncodeunits(XMLDOC)
    cells = join("<TD PORT=\"b$(i - 1)\" BGCOLOR=\"$((i - 1) in covered ? COVFILL : SRCFILL)\"><FONT FACE=\"Menlo\">$(hesc(c))</FONT></TD>"
                 for (i, c) in enumerate(XMLDOC))
    idx = join("<TD PORT=\"i$(i - 1)\" BORDER=\"0\"><FONT POINT-SIZE=\"8\" COLOR=\"#777777\">$(i - 1)</FONT></TD>" for i in 1:n)
    gap(k) = k > 0 ? "<TD COLSPAN=\"$k\" BORDER=\"0\"></TD>" : ""
    barrows = join("<TR><TD BORDER=\"0\" ALIGN=\"RIGHT\"><FONT FACE=\"Menlo\" POINT-SIZE=\"9\">$lbl</FONT>&#160;</TD>$(gap(a))" *
                   "<TD COLSPAN=\"$(b - a + 1)\" BGCOLOR=\"$READFILL\"><FONT POINT-SIZE=\"8\" COLOR=\"#555555\">bytes $a to $b</FONT></TD>$(gap(n - 1 - b))</TR>"
                   for (lbl, a, b) in bars)
    """src [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5"><TR><TD PORT="lbl" BORDER="0" ALIGN="RIGHT"><B>source</B> <FONT POINT-SIZE="9">(String)</FONT>&#160;</TD>$cells</TR><TR><TD BORDER="0"></TD>$idx</TR>$barrows</TABLE>>];"""
end

# The title of each diagram is the heading above it in READERS.md; the diagram keeps its counts.
header(sub) = """graph [rankdir=TB, fontname="Helvetica", fontsize=10, labelloc=t, bgcolor=white, nodesep=0.35, ranksep=0.5,
    label=<$sub<BR/> >];
  node [shape=plaintext, fontname="Helvetica", fontsize=11];
  edge [arrowsize=0.7, color="$REF", fontname="Helvetica", fontsize=9];"""

box(fill, rows; style = "") = "<<TABLE BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"4\" BGCOLOR=\"$fill\" COLOR=\"#4A6C8F\"$style>$rows</TABLE>>"
small(s; color = "#555555") = "<FONT POINT-SIZE=\"8\" COLOR=\"$color\">$s</FONT>"
strbox(s) = box(SRCFILL, "<TR><TD><FONT FACE=\"Menlo\">&quot;$s&quot;</FONT></TD></TR><TR><TD>$(small("String · 1 alloc."))</TD></TR>")
field(name, port) = "<TR><TD ALIGN=\"LEFT\">$name</TD><TD PORT=\"$port\">●</TD></TR>"
note(text) = "note [label=<<FONT POINT-SIZE=\"10\" COLOR=\"#333333\">$text</FONT>>];"
# Edge label on a near-opaque white ground, so that the arrow does not run through the text.
elabel(s) = "<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\" BGCOLOR=\"#FFFFFFE6\"><TR><TD><FONT POINT-SIZE=\"9\">$s</FONT></TD></TR></TABLE>>"

#-------------------------------------------------------------------------------# Node
nodebox(kind, rows) = box(OBJFILL, "<TR><TD COLSPAN=\"2\"><B>Node</B> · $kind  $(small("1 alloc."))</TD></TR>" * rows)
vecbox(title, cells) = box(TABFILL, "<TR><TD COLSPAN=\"3\"><B>$title</B>  $(small("2 alloc.: vector + Memory"))</TD></TR><TR>$cells</TR>")
node_buffers = join("<TR><TD ALIGN=\"LEFT\"><FONT FACE=\"Menlo\" POINT-SIZE=\"9\">$n</FONT></TD><TD ALIGN=\"LEFT\">$(small(t))</TD></TR>" for (n, t) in (
    ("tags", "Vector{String}: open tag names, to match end tags"),
    ("scratch_attrs", "Vector{Pair}: attributes of the open elements"),
    ("scratch_children", "Vector{Node}: children of the open elements"),
    ("attr_marks", "Vector{Int}: where each open element's attributes start"),
    ("child_marks", "Vector{Int}: where each open element's children start")))
node_dot = """digraph G {
  $(header("parse(xml, Node) on $EXAMPLE : 25 allocations = 15 kept in the tree (counted on each box) + 10 for the reader's buffers"))
  doc [label=$(nodebox("Document", field("children", "ch")))];
  v1  [label=$(vecbox("Vector{Node}", "<TD PORT=\"s1\" COLSPAN=\"3\">●</TD>"))];
  r   [label=$(nodebox("Element", field("tag", "tag") * field("attributes", "at") * field("children", "ch")))];
  sr  [label=$(strbox("rr"))];
  va  [label=$(vecbox("Vector{Pair}", "<TD PORT=\"k\">●</TD><TD>=&gt;</TD><TD PORT=\"v\">●</TD>"))];
  sa  [label=$(strbox("a"))];
  s1  [label=$(strbox("1"))];
  v2  [label=$(vecbox("Vector{Node}", "<TD PORT=\"s1\">●</TD><TD></TD><TD PORT=\"s2\">●</TD>"))];
  t   [label=$(nodebox("Text", field("value", "val")))];
  shi [label=$(strbox("hi"))];
  c   [label=$(nodebox("Element", field("tag", "tag") * "<TR><TD ALIGN=\"LEFT\">children</TD><TD><FONT COLOR=\"#777777\">nothing</FONT></TD></TR>"))];
  sc  [label=$(strbox("c"))];
  tmp [label=$(box(TMPFILL, "<TR><TD COLSPAN=\"2\"><B>The reader's buffers</B>  $(small("10 alloc.: 5 vectors + their Memory"))</TD></TR><TR><TD COLSPAN=\"2\">$(small("used while parsing, garbage once parse returns"))</TD></TR>" * node_buffers; style = " STYLE=\"dashed\""))];
  $(note("Each solid box stays in the tree, and each arrow is a reference the garbage collector follows.<BR/>4 Node + 5 String + 3 vectors × 2 = 15 allocations kept."))
  doc:ch -> v1; v1:s1 -> r; r:tag -> sr; r:at -> va; va:k -> sa; va:v -> s1; r:ch -> v2;
  v2:s1 -> t; v2:s2 -> c; t:val -> shi; c:tag -> sc;
  { rank=same; sr; va; v2; }
  { rank=same; doc; tmp; }
  shi -> note [style=invis]; sc -> note [style=invis];
}"""

#---------------------------------------------------------------------------# FlatNode
th(s) = "<TD BGCOLOR=\"#DDDDDD\"><B>$s</B></TD>"
# A cell that designates the source. Its text stays centred between two empty cells of width `w`, and
# the port is the left or the right one: the arrow leaves from the edge of its cell, then runs down the
# margin of the rows below, clear of their text (path set by `reroute_flat`).
const PORTSIDE = Dict("r2n" => (:left, 28), "r3v" => (:right, 28), "r4n" => (:right, 14))
function td(s; port = "")
    isempty(port) && return "<TD>$s</TD>"
    port == "r2a" && return "<TD PORT=\"$port\" BGCOLOR=\"#DCEFD8\">$s</TD>"
    side, w = PORTSIDE[port]
    pad = "<TD WIDTH=\"$w\"></TD>"; prt = "<TD PORT=\"$port\" WIDTH=\"$w\"></TD>"
    inner = side === :left ? prt * "<TD>$s</TD>" * pad : pad * "<TD>$s</TD>" * prt
    "<TD BGCOLOR=\"$COVFILL\"><TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"0\"><TR>$inner</TR></TABLE></TD>"
end
recs_rows = [
    ("1", "Document", "0", "2", "0", ("(0, 0)", ""), ("(-1, 0)", ""), ("(0, 0)", ""), "[0, 21)"),
    ("2", "Element", "1", "3", "0", ("(1, 2)", "r2n"), ("(-1, 0)", ""), ("(1, 1)", "r2a"), "[0, 21)"),
    ("3", "Text", "2", "0", "4", ("(0, 0)", ""), ("(10, 2)", "r3v"), ("(0, 0)", ""), "[10, 12)"),
    ("4", "Element", "2", "0", "0", ("(13, 1)", "r4n"), ("(-1, 0)", ""), ("(0, 0)", ""), "[12, 16)")]
recs_html = "<TR>" * th("i") * th("kind") * th("parent") * th("first child") * th("next sibling") * th("name (off, len)") *
            th("value (off, len)") * "<TD BGCOLOR=\"#E8E0F0\"><B>spans[i] [start, end)</B><BR/><FONT POINT-SIZE=\"8\" COLOR=\"#555555\">store.spans · 2 alloc.</FONT></TD>" * th("attrs (first, count)") * "</TR>" *
            join("<TR><TD PORT=\"row$(r[1])\"><B>$(r[1])</B></TD>" * td(r[2]) * td(r[3]) * td(r[4]) * td(r[5]) *
                 td(r[6][1]; port = r[6][2]) * td(r[7][1]; port = r[7][2]) * "<TD BGCOLOR=\"#F4F0F8\">$(r[9])</TD>" *
                 td(r[8][1]; port = r[8][2]) * "</TR>" for r in recs_rows)
flat_dot = """digraph G {
  $(header("parse(xml, FlatNode) on $EXAMPLE : 17 allocations = 7 kept (counted on each box) + 10 for the reader's buffers · a record is 40 bytes with no pointer"))
  h [label=$(box(OBJFILL, "<TR><TD><B>FlatNode</B>(store, i = 2)</TD></TR><TR><TD>$(small("a handle: the store and an index"))</TD></TR><TR><TD>$(small("parse returns the one for i = 1 · 1 alloc."))</TD></TR>"))];
  tmp [label=$(box(TMPFILL, "<TR><TD COLSPAN=\"2\"><B>The reader's buffers</B>  $(small("10 alloc."))</TD></TR><TR><TD COLSPAN=\"2\">$(small("used while parsing, garbage once parse returns"))</TD></TR>" * join("<TR><TD ALIGN=\"LEFT\"><FONT FACE=\"Menlo\" POINT-SIZE=\"9\">$n</FONT></TD><TD ALIGN=\"LEFT\">$(small(t))</TD></TR>" for (n, t) in (
      ("pstack", "Vector{Int32}: the open elements · 3 alloc. (it grew once)"),
      ("lastchild", "Vector{Int32}: last child of each open element, to link siblings · 3 alloc."),
      ("recs, spans", "their first Memory, replaced when they grew · 2 alloc."),
      ("children(doc)", "Vector{FlatNode} + Memory: the :structural check of the top level · 2 alloc.")));
      style = " STYLE=\"dashed\""))];
  recs [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="4"><TR><TD COLSPAN="9" BORDER="0" ALIGN="LEFT"><B>store.recs</B> <FONT POINT-SIZE="9">Vector{_FlatRec}</FONT>  $(small("2 alloc.: vector + Memory"))</TD></TR>$recs_html</TABLE>>];
  attrs [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="4"><TR><TD PORT="a1" BGCOLOR="#DCEFD8"><B>j = 1</B></TD><TD PORT="a1n" BGCOLOR="$COVFILL">name (4, 1)</TD><TD PORT="a1v" BGCOLOR="$COVFILL">value (7, 1)</TD></TR><TR><TD COLSPAN="3" BORDER="0" ALIGN="LEFT"><B>store.attrs</B> <FONT POINT-SIZE="9">Vector{_FlatAttr}, 16 bytes each</FONT>  $(small("2 alloc.: vector + Memory"))</TD></TR></TABLE>>];
  $(source_node(Set([1, 2, 4, 7, 10, 11, 13])))
  $(note("(off, len): the bytes from position off (counted from 0), len of them, shaded in the source; off = -1: no value.<BR/>[start, end): the node's bytes, start included, end excluded: [12, 16) is &lt;c/&gt;, bytes 12 to 15.<BR/>attrs (first, count): rows first to first + count - 1 of store.attrs, in green. Links are indices into recs (0 = none)."))
  { rank=same; h; tmp; }
  h -> recs:row2 [color="#4A6C8F"];
  recs:r2n:s -> src:b1:n [color="$POS"]; recs:r3v:s -> src:b10:n [color="$POS"]; recs:r4n:s -> src:b13:n [color="$POS"];
  src:i4:s -> attrs:a1n:n [color="$POS", dir=back]; src:i7:s -> attrs:a1v:n [color="$POS", dir=back];
  src -> attrs -> note [style=invis];
}"""

#---------------------------------------------------------------------------# LazyNode
handle(kind, tok; data = false) = box(OBJFILL, "<TR><TD COLSPAN=\"2\"><B>LazyNode</B> · $kind</TD></TR>" *
    "<TR><TD ALIGN=\"LEFT\">data</TD><TD><FONT COLOR=\"#777777\">$(data ? "the source" : "(same source)")</FONT></TD></TR>" *
    "<TR><TD ALIGN=\"LEFT\">token</TD><TD PORT=\"tok\" BGCOLOR=\"$COVFILL\"><FONT FACE=\"Menlo\">$tok</FONT></TD></TR>")
code(s) = "<<FONT FACE=\"Menlo\" POINT-SIZE=\"10\">$s</FONT>>"
alloc_title(n, what, size, why) = "<TR><TD COLSPAN=\"2\"><B>($n) $what</B> <FONT POINT-SIZE=\"9\">$size</FONT></TD></TR><TR><TD COLSPAN=\"2\"><FONT POINT-SIZE=\"9\" COLOR=\"#555555\">$why</FONT></TD></TR>"
lazy_dot = """digraph G {
  $(header("parse(xml, LazyNode) on $EXAMPLE : 0 allocations · each call to children(r) : 3 allocations, numbered (1) to (3)"))
  c1 [label=$(code("doc = parse(xml, LazyNode)"))];
  c2 [label=$(code("r = only(children(doc))"))];
  c3 [label=$(code("children(r)"))];
  hdoc [label=$(handle("Document", "TEXT @0+0"; data = true))];
  hr   [label=$(handle("Element", "OPEN_TAG @0+3"))];
  vec  [label=$(box(TABFILL, alloc_title(1, "Vector{LazyNode}", "32 bytes", "the result: a new vector at each call") * "<TR><TD ALIGN=\"LEFT\">ref</TD><TD PORT=\"mem\">●</TD></TR>"))];
  tkz  [label=$(box(TMPFILL, alloc_title(2, "StatefulTokenizer", "80 bytes", "a new one at each call: reads r again, up to<BR/>its end tag (bar children(r)), then is discarded") * "<TR><TD PORT=\"rd\" COLSPAN=\"2\"> </TD></TR>"; style = " STYLE=\"dashed\""))];
  mem  [label=<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="6" CELLPADDING="0" BGCOLOR="$TABFILL" COLOR="#4A6C8F"><TR><TD COLSPAN="2"><B>(3) Memory{LazyNode}</B> <FONT POINT-SIZE="9">136 bytes</FONT></TD></TR><TR><TD COLSPAN="2"><FONT POINT-SIZE="9" COLOR="#555555">the vector's storage; the handles sit in it</FONT></TD></TR><TR><TD PORT="t">$(handle("Text", "TEXT @10+2")[2:end-1])</TD><TD PORT="e">$(handle("Element", "OPEN_TAG @12+2")[2:end-1])</TD></TR></TABLE>>];
  $(source_node(Set([0, 1, 2, 10, 11, 12, 13]); bars = (("children(doc)", 0, 20), ("children(r)", 0, 19), ("children(c)", 12, 15))))
  $(note("@off+len: the token starts at byte off (counted from 0) and covers len bytes, shaded in the source; an open-tag token covers « &lt; » and the name.<BR/>A handle holds the source, one token and the node kind. For its 3 allocations, children(r) gives the handles of r's children, one level only.<BR/>Nothing is kept: a second call allocates again. Red bars: the tokens each call to children reads, to find where each child ends."))
  c1:s -> hdoc:n [style=dashed, arrowhead=none]; c2:s -> hr:n [style=dashed, arrowhead=none];
  c3:s -> tkz:n [style=dashed, arrowhead=none]; c3:s -> vec:n [style=dashed, arrowhead=none];
  { rank=same; c1 -> c2 -> c3 [style=invis]; }
  { rank=same; hdoc -> hr -> tkz -> vec [style=invis]; }
  vec:mem:s -> mem:n [color="$REF"];
  hdoc:s -> src:lbl:n [color="$REF", xlabel=$(elabel("data"))];
  hr:tok:s -> src:b0:n [color="$POS", xlabel=$(elabel("@0+3"))];
  tkz:s -> src:b0:n [color="$REF", style=dashed];
  mem:t:s -> src:b10:n [color="$POS", xlabel=$(elabel("@10+2"))];
  mem:e:s -> src:b12:n [color="$POS", xlabel=$(elabel("@12+2"))];
  src -> note [style=invis];
}"""

#----------------------------------------------------------------------------# arrows
# dot does not let an edge's shape be chosen: around a neighbouring box it breaks the curve. The paths
# below replace the `pos` of single edges in dot's own layout (`dot -Tdot`), which `neato -n2` then
# renders unchanged. Coordinates are points, y pointing up.
straight(a, b) = [a .+ (b .- a) ./ 3, a .+ 2 .* (b .- a) ./ 3, b]
scurve(a, b) = [(a[1], (a[2] + b[2]) / 2), (b[1], (a[2] + b[2]) / 2), b]   # vertical at both ends
fmtp(p) = string(round(p[1]; digits = 2), ",", round(p[2]; digits = 2))
function edge_pos(laid, edge)
    i = findfirst(edge, laid); i === nothing && error("edge not found: $edge")
    j = findnext("pos=\"", laid, last(i)); k = findnext('"', laid, last(j) + 1)
    pts = split(laid[last(j)+1:k-1])
    (last(j)+1:k-1, pts)
end
pt(s) = Tuple(parse.(Float64, split(s, ',')))
function node_box(laid, name)
    m = match(Regex("\\n\\s*$name\\s+\\[height=([\\d.]+)"), laid)
    pm = match(r"pos=\"([-\d.]+),([-\d.]+)\"", laid, m.offset)
    wm = match(r"\bwidth=([\d.]+)", laid, pm.offset)
    (x = parse(Float64, pm[1]), y = parse(Float64, pm[2]), w = 72parse(Float64, wm[1]), h = 72parse(Float64, m[1]))
end
# An edge with an arrowhead: `pos` starts with "e,x,y", the tip; `segs_of(tip, start)` gives the rest.
function set_arrow(laid, edge, segs_of)
    rng, pts = edge_pos(laid, edge)
    tip = pt(pts[1][3:end]); p0 = pt(pts[2])
    laid[1:first(rng)-1] * "e," * fmtp(tip) * " " * join(fmtp.([p0; segs_of(tip, p0)]), " ") * laid[last(rng)+1:end]
end
# An edge without arrowhead, at a small drop: two quarter ellipses (κ = 0.5523), vertical at both ends
# and horizontal in the middle. dot's single curve would rise above its end point.
function set_flat_s(laid, edge)
    rng, pts = edge_pos(laid, edge)
    p0 = pt(pts[1]); p3 = pt(pts[end]); κ = 0.5523
    xm = (p0[1] + p3[1]) / 2; ym = (p0[2] + p3[2]) / 2; w = xm - p0[1]; h = p0[2] - ym
    q = [p0, (p0[1], p0[2] - κ * h), (xm - κ * w, ym), (xm, ym), (xm + κ * w, ym), (p3[1], p3[2] + κ * h), p3]
    laid[1:first(rng)-1] * join(fmtp.(q), " ") * laid[last(rng)+1:end]
end
const ARROW = 7.0   # arrowhead length at arrowsize 0.7
function reroute_lazy(laid)
    laid = replace(laid, "\\\n" => "")   # dot breaks long strings with a backslash and a newline
    # The tokenizer's arrow: an S from the bottom of its box to the first byte.
    laid = set_arrow(laid, "tkz:s -> src:b0:n", (tip, p0) -> scurve(p0, (tip[1], tip[2] + ARROW)))
    set_flat_s(laid, "c3:s -> vec:n")
end
# FlatNode: each position arrow of `store.recs` runs down the margin of the rows below its cell, then
# joins the source with an S. The arrows of rows 3 and 4 cross once between the table and the source:
# the value column is right of the name column, while byte 10 is left of byte 13.
function reroute_flat(laid)
    laid = replace(laid, "\\\n" => "")
    recs = node_box(laid, "recs"); src = node_box(laid, "src")
    ytb = recs.y - recs.h / 2                 # bottom of the table
    ytop = src.y + src.h / 2 + ARROW          # foot of an arrowhead resting on the source
    down_then_s(tip, p0) = [straight(p0, (p0[1], ytb)); scurve((p0[1], ytb), (tip[1], ytop))]
    laid = set_arrow(laid, "recs:r2n:s -> src:b1:n", down_then_s)
    laid = set_arrow(laid, "recs:r3v:s -> src:b10:n", down_then_s)
    set_arrow(laid, "recs:r4n:s -> src:b13:n", (tip, p0) -> scurve(p0, (tip[1], ytop)))
end

#----------------------------------------------------------------------------# render
mktempdir() do tmp
    for (name, src, reroute) in (("reader-node", node_dot, identity), ("reader-flatnode", flat_dot, reroute_flat),
                                 ("reader-lazynode", lazy_dot, reroute_lazy))
        dotfile = joinpath(tmp, name * ".dot")
        write(dotfile, src)
        fixed = joinpath(tmp, name * "-fixed.dot")
        write(fixed, reroute(read(`$(dot()) -Tdot $dotfile`, String)))
        svg = joinpath(OUT, name * ".svg")
        run(`$(dot()) -Kneato -n2 -Tsvg:cairo $fixed -o $svg`)
        println(relpath(svg, dirname(OUT)), " written")
    end
end
