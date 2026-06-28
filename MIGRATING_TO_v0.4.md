# Migrating from XML.jl 0.3 to 0.4

XML.jl 0.4 replaces the `Raw`/`LazyNode` streaming internals with a token-based parser and a
pull/cursor API, and tightens several behaviors to follow the XML specification more closely. The
high-level DOM workflow — `parse`, `read`, `Node`, `children`, `tag`, `attributes`, `value`,
`XML.write` — is largely source-compatible. For most packages the upgrade is a `[compat]` bump plus
a review of the **Behavioral changes** below.

## At a glance

- Bump `[compat]` to `XML = "0.4"`; XML.jl 0.4 requires **Julia ≥ 1.10**.
- If you only build, read, and write trees through the accessor functions, you most likely just need
  to read **Behavioral changes**.
- If you used `Raw`, `LazyNode`, `next`/`prev`, or read `node.attributes` directly, see **Removed
  APIs** and **Structural changes**.

## Removed APIs and their replacements

| 0.3.x | 0.4 |
| --- | --- |
| `XML.Raw(...)`, `LazyNode(raw)` | `parse(str, Node)` / `read(file, Node)`; or `Cursor` for streaming |
| `next(node)` / `prev(node)` | parse to a `Node`, then `children(node)` / `node[i]`; or `Cursor` + `next!` |
| `parent(node)` (1-arg) | `parent(child, root)` |
| `depth(node)` (1-arg) | `depth(child, root)` |
| `nodes_equal(a, b)` | `a == b` |
| `escape!(node)` / `unescape!(node)` | automatic during `XML.write` / `parse` |
| `DTDBody` | `parse_dtd(...)` / the `DTD` node |
| `simplevalue` | `simple_value` (deprecated alias still works) |

Calling a removed function raises an error whose message names the replacement. `DTDBody` is removed
outright (it raises `UndefVarError`).

## Structural changes

### Attributes are a `Vector{Pair}` behind an accessor

0.3.x stored attributes as an `OrderedDict` in the `Node` field. 0.4 stores a `Vector{Pair}` and
exposes them through the `attributes` accessor, which returns an ordered `Attributes <: AbstractDict`
(or `nothing` when there are none):

```julia
# 0.3.x — indexing the field directly
node.attributes["class"]

# 0.4 — use the accessor (or string-index the Node)
attrs = attributes(node)            # Attributes <: AbstractDict, or nothing
attrs === nothing || attrs["class"]
node["class"]                       # string-indexing a Node also returns an attribute value
```

`Attributes` supports the full `AbstractDict` interface (`get`, `haskey`, `keys`, `values`,
iteration) and preserves document order.

### `Node` is parametric

`Node` is now `Node{S}`, where `S` is the string storage type (`String`, or `SubString{String}` for
zero-copy parsing). `::Node` annotations still work. If you dispatched on `::AbstractXMLNode`, note
that `Node` is no longer a subtype of it.

The zero-copy `Node{SubString{String}}` variant returns text and attribute values **raw** — entities
such as `&amp;` are *not* decoded, since decoding would require allocating a new string. The default
`Node` (`Node{String}`), `LazyNode`, and `Cursor` all decode entities into values.

### `LazyNode` is an immutable view

```julia
# 0.3.x
ln = LazyNode(Raw(read("f.xml")))      # mutable; had a `.raw` field

# 0.4
ln = read("f.xml", LazyNode)           # immutable; accessors return SubString views
```

The `.raw` field is gone. Use the accessors (`tag`, `value`, `attributes`, `children`, indexing).
`LazyNode` still provides the same read-only interface as `Node`.

### Constructing nodes

`Node` constructors validate their arguments by node type. Processing instructions take a content
string, not attributes:

```julia
ProcessingInstruction("xml-stylesheet", "type=\"text/xsl\" href=\"style.xsl\"")
```

Element and PI names must be valid XML names, and `Comment` / `CData` / `ProcessingInstruction`
content may not contain its own close delimiter — so a constructed node can never serialize to
malformed XML. These now raise instead of producing un-parseable output:

```julia
Element("")        # empty name  ->  would write "</>"
Element("1bad")    # name starts with a digit
Comment("a-->b")   # "-->" would close the comment early
CData("a]]>b")     # "]]>" would close the section early
```

## Behavioral changes (same call, different result)

Review these even if your code compiles unchanged:

1. **Automatic escaping in `write`.** `XML.write` escapes text and attribute values for you. Remove
   any manual pre-escaping (the old `escape!`) or you will double-escape.

2. **Decoded values.** `value(node)` returns *unescaped* text — `&`, not `&amp;`. Because `write`
   re-escapes on output, round-trips are preserved; but if you compared `value(node)` against escaped
   string literals, update those comparisons.

3. **`escape` is not idempotent — only escape *raw* text.** Every `&` is escaped, so text that
   already contains an entity-like sequence is escaped again: `escape("5 &amp; 6")` →
   `"5 &amp;amp; 6"`. This is deliberate — it makes `escape` the exact inverse of `unescape` for
   *any* string (`unescape(escape(x)) == x`); the old idempotent version silently lost data,
   round-tripping `"5 &amp; 6"` down to `"5 & 6"`. Don't call `escape` on possibly-escaped text —
   and note `XML.write` escapes for you on output.

4. **Duplicate attributes are an error.** A document with repeated attribute names that parsed in
   0.3.x now raises `"Duplicate attribute: …"`.

5. **Stricter parsing by default.** `parse`/`read` default to `wellformed = :structural`, which
   rejects: multiple root elements; a document with **no** root element; non-whitespace text outside
   the root; empty or invalid element names; a literal `<` in an attribute value; and a misplaced,
   duplicate, or nested DOCTYPE or XML declaration.

   ```julia
   parse(str, Node)                          # :structural (default)
   parse(str, Node; wellformed = :lenient)   # previous permissive behavior
   parse(str, Node; wellformed = :strict)    # see below
   ```

   `:strict` additionally rejects: `--` (or a trailing `-`) inside a comment; an empty or invalid
   processing-instruction target; and any character — whether a numeric **reference** (`&#0;`) or a
   **raw** literal character — outside the XML 1.0 §2.2 `Char` range (e.g. NUL and other control
   characters). Because that adds a full character-range scan over textual content, `:strict` is
   meaningfully slower than `:structural` on text-heavy documents — a cost paid only when you opt in
   (`:lenient` and `:structural` are unaffected).

   A consequence of requiring a root element: input that is **not a complete document** — a
   standalone DTD file, or a prolog-only fragment — is now rejected at `:structural`. Read it with
   `wellformed = :lenient`:

   ```julia
   read("schema.dtd", Node; wellformed = :lenient)   # a DTD file has no root element
   ```

7. **Inter-element whitespace is preserved.** `parse`/`read` keep whitespace-only text between
   elements as `Text` nodes (0.3.x dropped it by default). So `children(root)` may include leading
   `Text` nodes, and `children(root)[1]` is **not** necessarily the first child *element*. Filter by
   `nodetype` (or use `XML.simple_value` / the typed accessors) if you need elements only:

   ```julia
   first(c for c in children(root) if nodetype(c) === Element)
   ```

8. **`LazyNode` and `Cursor` do not check well-formedness.** Only `Node` enforces the `wellformed`
   level; `parse(x, LazyNode)` and `Cursor(x)` tokenize without validating and do not accept a
   `wellformed` keyword. Parse through `Node` if you need well-formedness checking.

6. **No memory-mapping.** `read` no longer memory-maps the input file.

## Compat

```toml
[compat]
XML = "0.4"
julia = "1.10"
```

## Replacing streaming code

The old `Raw`/`LazyNode` forward/backward streaming is replaced by two options:

- **Full tree** — `parse(str, Node)` / `read(file, Node)`, then navigate with `children`, `tag`,
  `attributes`, `value`, and integer indexing.
- **Pull/cursor streaming** (for large documents you don't want to fully materialize):

  ```julia
  c = Cursor(data)
  while next!(c) !== nothing
      nodetype(c) === Element || continue
      # inspect tag(c), attributes, etc.; skip_element!(c) to skip a subtree
  end
  ```

  (`Cursor` is forward-only; there is no `prev!`.) `for_each_child` / `@for_each_child` iterate the
  children at the current position.

**Choosing a reader.** For forward streaming of a large document, prefer `Cursor` (fastest,
allocation-free). For repeated or random access, prefer `Node` (it builds the tree once, then walks
cheaply). Reach for `LazyNode` only when you need low-memory, *read-once* navigation: it holds no
tree (≈ an order of magnitude less resident memory than `Node`) but re-tokenizes on every traversal,
so it is the slowest choice for repeated walks.

## Known limitations

- **`parent` / `depth` / `siblings` and the XPath `..` axis address nodes by value.** Because `Node`
  is an immutable value type, these locate the node within the tree by structural equality (`===`).
  For a tree containing **value-identical** sibling nodes — e.g. two empty `<item/>` elements — they
  may return the result for the *first* such node rather than the specific one you passed. Trees whose
  repeated nodes differ in content are unaffected. A redesign (path-based addressing) is planned for a
  later release.
- **Top-level CDATA is not rejected.** A CDATA section in the prolog or epilog — outside the root
  element — is accepted even at `:strict`, although XML 1.0 (`Misc` excludes `CDATA`) makes it
  ill-formed. CDATA *inside* an element is of course valid. A stricter check may be added later.

## See also

- [`CHANGELOG.md`](CHANGELOG.md) — the complete list of changes in 0.4.
