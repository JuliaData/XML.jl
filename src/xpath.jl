#-----------------------------------------------------------------------------# XPath
# A subset of XPath 1.0 for querying XML.Node trees.
#
# Supported syntax:
#   /            root (absolute path)
#   tag          child element by name
#   *            any child element
#   //           descendant-or-self (recursive)
#   .            current node
#   ..           parent node
#   [n]          positional predicate (1-based)
#   [@attr]      has-attribute predicate
#   [@attr='v']  attribute-value predicate
#   text()       text node children
#   node()       all node children
#   @attr        attribute value (as a Text node)

#-----------------------------------------------------------------------------# Token types

"""
    XPathTokenKind

Discriminator for the kinds of tokens produced by [`_xpath_tokenize`](@ref).

| Variant            | Source syntax            |
|--------------------|--------------------------|
| `XPATH_ROOT`       | `/` (path separator)     |
| `XPATH_DESCENDANT` | `//`                     |
| `XPATH_NAME`       | element tag name         |
| `XPATH_WILDCARD`   | `*`                      |
| `XPATH_DOT`        | `.` (self)               |
| `XPATH_DOTDOT`     | `..` (parent)            |
| `XPATH_TEXT_FN`    | `text()`                 |
| `XPATH_NODE_FN`    | `node()`                 |
| `XPATH_PREDICATE`  | `[...]` body             |
| `XPATH_ATTRIBUTE`  | `@attr` (result position) |
"""
@enum XPathTokenKind::UInt8 begin
    XPATH_ROOT           # /
    XPATH_DESCENDANT     # //
    XPATH_NAME           # tag name
    XPATH_WILDCARD       # *
    XPATH_DOT            # .
    XPATH_DOTDOT         # ..
    XPATH_TEXT_FN        # text()
    XPATH_NODE_FN        # node()
    XPATH_PREDICATE      # [...]
    XPATH_ATTRIBUTE      # @attr (in result position)
end

"""
    XPathToken

A single token from a parsed XPath expression: a [`XPathTokenKind`](@ref) tag together with
the relevant textual payload (tag name, predicate body, attribute name, etc.). Tokens with
no payload (`XPATH_ROOT`, `XPATH_WILDCARD`, …) carry the literal source character(s) for
debuggability.
"""
struct XPathToken
    kind::XPathTokenKind
    value::String
end

#-----------------------------------------------------------------------------# Names and white space

# A name in an expression follows XML 1.0's Name rule (fifth edition, §2.3), except that it cannot
# start with ":". These are the non-ASCII code points of NameStartChar, then those NameChar adds.
const _NAME_START_RANGES = (0xC0:0xD6, 0xD8:0xF6, 0xF8:0x2FF, 0x370:0x37D, 0x37F:0x1FFF,
    0x200C:0x200D, 0x2070:0x218F, 0x2C00:0x2FEF, 0x3001:0xD7FF, 0xF900:0xFDCF, 0xFDF0:0xFFFD,
    0x10000:0xEFFFF)
const _NAME_CHAR_RANGES = (0xB7:0xB7, 0x300:0x36F, 0x203F:0x2040)

_in_ranges(c::Char, ranges) = !isascii(c) && isvalid(c) && any(r -> codepoint(c) in r, ranges)
_xpath_name_start(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '_' ||
    _in_ranges(c, _NAME_START_RANGES)
_xpath_name_char(c::Char) = _xpath_name_start(c) || ('0' <= c <= '9') || c == '-' || c == '.' ||
    c == ':' || _in_ranges(c, _NAME_CHAR_RANGES)

# The index just past the name that starts at index i of s, or i when no name starts there
function _xpath_name_end(s::AbstractString, i::Int)
    n = ncodeunits(s)
    (i <= n && _xpath_name_start(s[i])) || return i
    j = nextind(s, i)
    while j <= n && _xpath_name_char(s[j])
        j = nextind(s, j)
    end
    j
end
_is_xpath_name(s::AbstractString) = !isempty(s) && _xpath_name_end(s, 1) == ncodeunits(s) + 1

# XPath white space is XML's: space, tab, line feed and carriage return
_is_xpath_space(c::Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r'

#-----------------------------------------------------------------------------# Tokenizer

# Lex an XPath expression into a flat token stream. Whitespace is discarded; unterminated
# predicates / function calls and unrecognised characters raise an error. Tokens preserve
# source order and are consumed left-to-right by `xpath`.
function _xpath_tokenize(expr::AbstractString)
    tokens = XPathToken[]
    s = String(expr)
    i = 1
    n = ncodeunits(s)

    while i <= n
        c = s[i]

        if c == '/'
            if i < n && s[i+1] == '/'
                push!(tokens, XPathToken(XPATH_DESCENDANT, "//"))
                i += 2
            else
                push!(tokens, XPathToken(XPATH_ROOT, "/"))
                i += 1
            end

        elseif c == '.'
            if i < n && s[i+1] == '.'
                push!(tokens, XPathToken(XPATH_DOTDOT, ".."))
                i += 2
            else
                push!(tokens, XPathToken(XPATH_DOT, "."))
                i += 1
            end

        elseif c == '*'
            push!(tokens, XPathToken(XPATH_WILDCARD, "*"))
            i += 1

        elseif c == '['
            j = findnext(']', s, i + 1)
            isnothing(j) && error("Unterminated predicate in XPath: $(repr(s))")
            push!(tokens, XPathToken(XPATH_PREDICATE, SubString(s, i + 1, prevind(s, j))))
            i = j + 1

        elseif c == '@'
            j = _xpath_name_end(s, i + 1)
            j == i + 1 && error("Expected an attribute name after @ in XPath: $(repr(s))")
            push!(tokens, XPathToken(XPATH_ATTRIBUTE, SubString(s, i + 1, prevind(s, j))))
            i = j

        elseif _xpath_name_start(c)
            j = _xpath_name_end(s, i)
            name = SubString(s, i, prevind(s, j))
            # An axis specifier ("axis::test", e.g. child::, descendant::, following-sibling::) is
            # out of this subset. Reject it rather than treat "axis::test" as a literal element name
            # (the "::" is swept into the name scan), which silently matches nothing. A single ":"
            # (a namespaced name like "ns:item") is fine.
            occursin("::", name) && error("unsupported XPath axis in $(repr(String(name))): only the implicit child and @attribute axes are supported")
            # Check for function calls: text(), node()
            if j <= n && s[j] == '('
                j2 = findnext(')', s, j + 1)
                isnothing(j2) && error("Unterminated function call in XPath: $(repr(s))")
                if name == "text"
                    push!(tokens, XPathToken(XPATH_TEXT_FN, "text()"))
                elseif name == "node"
                    push!(tokens, XPathToken(XPATH_NODE_FN, "node()"))
                else
                    error("Unknown XPath function: $name()")
                end
                i = j2 + 1
            else
                push!(tokens, XPathToken(XPATH_NAME, String(name)))
                i = j
            end

        elseif _is_xpath_space(c)
            i += 1

        else
            error("Unexpected character '$(c)' in XPath: $(repr(s))")
        end
    end
    tokens
end

#-----------------------------------------------------------------------------# Predicate evaluation

# The attribute name is captured loosely, then checked with the rule of the tokenizer's names
const _RE_ATTR_PRED = r"^@([^ \t\n\r='\"]+)$"
const _RE_ATTR_VAL_PRED = r"^@([^ \t\n\r='\"]+)[ \t\n\r]*=[ \t\n\r]*['\"]([^'\"]*)['\"]$"

# Filter `nodes` by the body of a `[...]` predicate. Supports positional indices `[n]`
# (1-based; out-of-range yields empty), `[last()]`, `[@attr]` (has-attribute), and
# `[@attr='value']` / `[@attr="value"]` (attribute equals literal). Anything else errors.
# `root` is accepted for symmetry with `_xpath_step` but is unused by current predicates.
function _eval_predicate(predicate::AbstractString, nodes::Vector{Node{S}}, root::Node{S}) where S
    s = strip(_is_xpath_space, predicate)

    # Positional: [n] (tryparse would skip any white space isspace knows, not only XPath's)
    pos = any(isspace, s) ? nothing : tryparse(Int, s)
    if !isnothing(pos)
        1 <= pos <= length(nodes) || return Node{S}[]
        return [nodes[pos]]
    end

    # last()
    if s == "last()"
        isempty(nodes) && return Node{S}[]
        return [nodes[end]]
    end

    # [@attr] — has attribute
    m = match(_RE_ATTR_PRED, s)
    if !isnothing(m) && _is_xpath_name(m.captures[1])
        attr_name = m.captures[1]
        return filter(n -> n.nodetype === Element && haskey(n, attr_name), nodes)
    end

    # [@attr='value'] or [@attr="value"]
    m = match(_RE_ATTR_VAL_PRED, s)
    if !isnothing(m) && _is_xpath_name(m.captures[1])
        attr_name = m.captures[1]
        attr_val = m.captures[2]
        return filter(n -> n.nodetype === Element && get(n, attr_name, nothing) == attr_val, nodes)
    end

    error("Unsupported XPath predicate: [$predicate]")
end

#-----------------------------------------------------------------------------# Step evaluation

# Apply a single non-predicate, non-descendant step to the current context and return the
# new context. Handles XPATH_NAME, XPATH_WILDCARD, XPATH_DOT, XPATH_DOTDOT, XPATH_TEXT_FN,
# XPATH_NODE_FN. XPATH_DESCENDANT is intentionally not handled here — the main evaluator
# expands `//` to descendant-or-self before the next step. `root` is used by `..` to avoid
# walking past the document root.
function _xpath_step(nodes::Vector{Node{S}}, token::XPathToken, root::Node{S}) where S
    result = Node{S}[]
    k = token.kind

    if k === XPATH_NAME
        for n in nodes
            for c in children(n)
                c.nodetype === Element && c.tag == token.value && push!(result, c)
            end
        end

    elseif k === XPATH_WILDCARD
        for n in nodes
            for c in children(n)
                c.nodetype === Element && push!(result, c)
            end
        end

    elseif k === XPATH_DOT
        append!(result, nodes)

    elseif k === XPATH_DOTDOT
        for n in nodes
            n === root && continue
            acc = Node[]
            _find_parents!(acc, n, root)
            isempty(acc) && continue
            length(acc) > 1 && error(_AMBIGUOUS_NODE_MSG)
            push!(result, acc[1])
        end

    elseif k === XPATH_TEXT_FN
        for n in nodes
            for c in children(n)
                c.nodetype === Text && push!(result, c)
            end
        end

    elseif k === XPATH_NODE_FN
        for n in nodes
            append!(result, children(n))
        end

    elseif k === XPATH_DESCENDANT
        # Handled by caller — collects all descendants before next step
        error("XPATH_DESCENDANT should be handled by the evaluator, not _xpath_step")
    end

    result
end

# Append every descendant of `node` (children, grandchildren, ...) to `out` in document
# order. Does not include `node` itself.
function _descendants!(out::Vector{Node{S}}, node::Node{S}) where S
    for c in children(node)
        push!(out, c)
        _descendants!(out, c)
    end
end

# Implements XPath's descendant-or-self axis: for each input node, emit the node itself
# followed by all of its descendants in document order.
function _descendants(nodes::Vector{Node{S}}) where S
    result = Node{S}[]
    for n in nodes
        push!(result, n)  # descendant-or-self includes self
        _descendants!(result, n)
    end
    result
end

#-----------------------------------------------------------------------------# Main evaluator

"""
    xpath(node::Node, expr::AbstractString) -> Vector{Node}

Evaluate an XPath expression against a `Node` tree and return matching nodes.

Supports a practical subset of XPath 1.0:
- Absolute (`/root/child`) and relative (`child/sub`) paths
- Recursive descent (`//tag`)
- Wildcards (`*`), self (`.`), parent (`..`)
- Positional predicates (`[1]`, `[last()]`)
- Attribute predicates (`[@attr]`, `[@attr='value']`)
- `text()` and `node()` functions
- Attribute selection (`@attr`) — returns `Text` nodes containing attribute values

Names follow XML 1.0's Name rule, in any script (`//é`, `//@ü`). White space is XML's (space,
tab, line feed, carriage return), inside predicates too.

# Examples
```julia
doc = parse("<root><a x='1'/><a x='2'/><b/></root>", Node)
xpath(doc, "/root/a")          # both <a> elements
xpath(doc, "/root/a[1]")       # first <a>
xpath(doc, "//a[@x='2']")      # <a x="2"/>
xpath(doc, "/root/b/@x")       # attribute value as Text node (empty here)
```
"""
function xpath(node::Node{S}, expr::AbstractString) where S
    tokens = _xpath_tokenize(expr)
    isempty(tokens) && return Node{S}[]

    root = node   # context node for `..` navigation

    # Start context: the walk begins at `node` itself. A leading "/" (absolute path) just consumes
    # the XPATH_ROOT token so the first step matches node's children. Node has no parent link, so an
    # absolute path from a non-Document node cannot re-anchor at the document root — it is evaluated
    # relative to `node`; pass a Document (or doc[1]) for a true absolute path.
    current = Node{S}[node]
    i = tokens[1].kind === XPATH_ROOT ? 2 : 1

    while i <= length(tokens)
        tok = tokens[i]

        if tok.kind === XPATH_PREDICATE
            current = _eval_predicate(tok.value, current, root)
            i += 1

        elseif tok.kind === XPATH_DESCENDANT
            current = _descendants(current)
            # // must be followed by a step
            i += 1

        elseif tok.kind === XPATH_ROOT
            # / as separator between steps — skip
            i += 1

        elseif tok.kind === XPATH_ATTRIBUTE
            # @attr in result position — return attribute values as Text nodes
            result = Node{S}[]
            for n in current
                v = get(n, tok.value, nothing)
                !isnothing(v) && push!(result, Node{S}(Text, nothing, nothing, v, nothing))
            end
            current = result
            i += 1

        else
            current = _xpath_step(current, tok, root)
            i += 1
        end
    end

    current
end
