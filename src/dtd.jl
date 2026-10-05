#-----------------------------------------------------------------------------# DTD parsing
struct ElementDecl
    name::String
    content::String  # "EMPTY", "ANY", or content model like "(#PCDATA)" or "(a,b,c)*"
end

struct AttDecl
    element::String
    name::String
    type::String     # "CDATA", "ID", "(val1|val2)", "NOTATION (a|b)", etc.
    default::String  # "#REQUIRED", "#IMPLIED", "#FIXED \"val\"", or "\"val\""
end

struct EntityDecl
    name::String
    value::Union{Nothing, String}       # replacement text (internal entities)
    external_id::Union{Nothing, String} # "SYSTEM \"uri\"" or "PUBLIC \"pubid\" \"uri\""
    parameter::Bool
end

struct NotationDecl
    name::String
    external_id::String
end

struct ParsedDTD
    root::String
    system_id::Union{Nothing, String}
    public_id::Union{Nothing, String}
    elements::Vector{ElementDecl}
    attributes::Vector{AttDecl}
    entities::Vector{EntityDecl}
    notations::Vector{NotationDecl}
end

# DTD parsing helpers — each returns (parsed_piece, new_pos) so calls compose.

# A character that can appear in an XML Name (letters, digits, `_`, `-`, `.`, `:`, and any
# non-ASCII char — mirrors the tokenizer's lenient NAME_BYTE_TABLE rule).
@inline _dtd_is_name_char(c::Char) =
    ('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') ||
    c == '_' || c == '-' || c == '.' || c == ':' || !isascii(c)

# Advance past any whitespace.
# One step forward, tolerant of running past the end: each reader tests `pos <= ncodeunits`
# before it indexes, so a step beyond the last character only has to keep the loop terminating.
@inline _dtd_next(s, pos) = pos <= ncodeunits(s) ? nextind(s, pos) : pos + 1

# The DTD readers walk a String by index, so every step goes through `nextind`: a `pos + 1`
# lands inside a character as soon as the subset holds one that is not ASCII — in a comment,
# an entity value or a name — and indexing there throws.
function _dtd_skip_ws(s, pos)
    while pos <= ncodeunits(s) && isspace(s[pos])
        pos = _dtd_next(s, pos)
    end
    pos
end

# Read an XML Name token; errors if no name characters are present.
function _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    start = pos
    while pos <= ncodeunits(s) && _dtd_is_name_char(s[pos])
        pos = nextind(s, pos)
    end
    start == pos && error("Expected name at position $pos in DTD")
    SubString(s, start, prevind(s, pos)), pos
end

# Read a `"..."` or `'...'` string and return the contents without the surrounding quotes.
function _dtd_read_quoted(s, pos)
    pos = _dtd_skip_ws(s, pos)
    q = s[pos]
    (q == '"' || q == '\'') || error("Expected quoted string at position $pos in DTD")
    pos = _dtd_next(s, pos)
    start = pos
    while pos <= ncodeunits(s) && s[pos] != q
        pos = _dtd_next(s, pos)
    end
    val = SubString(s, start, prevind(s, pos))
    pos = _dtd_next(s, pos)
    val, pos
end

# Read a balanced parenthesized expression (e.g. `(a|b|(c,d))`), returning the full
# substring including the outer `(` and `)`. Skips over quoted strings inside. Steps by
# character, like the other readers: an enumerated value can be a name beyond ASCII.
function _dtd_read_parens(s, pos)
    pos = _dtd_skip_ws(s, pos)
    s[pos] == '(' || error("Expected '(' at position $pos in DTD")
    depth = 1
    start = pos
    pos = _dtd_next(s, pos)
    while pos <= ncodeunits(s) && depth > 0
        c = s[pos]
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == '"' || c == '\''
            pos = _dtd_next(s, pos)
            while pos <= ncodeunits(s) && s[pos] != c
                pos = _dtd_next(s, pos)
            end
        end
        pos = _dtd_next(s, pos)
    end
    SubString(s, start, prevind(s, min(pos, ncodeunits(s) + 1))), pos
end

# Advance past the next `>` that terminates a markup declaration, ignoring `>` inside
# quoted strings.
function _dtd_skip_to_close(s, pos)
    while pos <= ncodeunits(s) && s[pos] != '>'
        c = s[pos]
        if c == '"' || c == '\''
            pos = _dtd_next(s, pos)
            while pos <= ncodeunits(s) && s[pos] != c
                pos = _dtd_next(s, pos)
            end
        end
        pos = _dtd_next(s, pos)
    end
    _dtd_next(s, pos)
end

# Parse `<!ELEMENT name content>` — content is either a name (EMPTY/ANY) or a parens
# group with an optional `*`/`+`/`?` quantifier appended.
function _dtd_parse_element(s, pos)
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    if s[pos] == '('
        content, pos = _dtd_read_parens(s, pos)
        if pos <= ncodeunits(s) && s[pos] in ('*', '+', '?')
            content = string(content, s[pos])
            pos += 1
        end
    else
        content, pos = _dtd_read_name(s, pos)
    end
    pos = _dtd_skip_to_close(s, pos)
    ElementDecl(String(name), String(content)), pos
end

# Parse `<!ATTLIST element name type default ...>` — emits one AttDecl per attribute.
function _dtd_parse_attlist(s, pos)
    element, pos = _dtd_read_name(s, pos)
    atts = AttDecl[]
    while true
        pos = _dtd_skip_ws(s, pos)
        (pos > ncodeunits(s) || s[pos] == '>') && break

        name, pos = _dtd_read_name(s, pos)
        pos = _dtd_skip_ws(s, pos)

        # Attribute type
        if s[pos] == '('
            atype, pos = _dtd_read_parens(s, pos)
        else
            atype, pos = _dtd_read_name(s, pos)
            if atype == "NOTATION"
                pos = _dtd_skip_ws(s, pos)
                parens, pos = _dtd_read_parens(s, pos)
                atype = string("NOTATION ", parens)
            end
        end
        pos = _dtd_skip_ws(s, pos)

        # Default declaration
        if s[pos] == '#'
            pos += 1
            keyword, pos = _dtd_read_name(s, pos)
            if keyword == "FIXED"
                pos = _dtd_skip_ws(s, pos)
                val, pos = _dtd_read_quoted(s, pos)
                default = string("#FIXED \"", val, "\"")
            else
                default = string("#", keyword)
            end
        elseif s[pos] == '"' || s[pos] == '\''
            val, pos = _dtd_read_quoted(s, pos)
            default = string("\"", val, "\"")
        else
            error("Expected default declaration at position $pos in DTD")
        end
        push!(atts, AttDecl(String(element), String(name), String(atype), default))
    end
    pos <= ncodeunits(s) && s[pos] == '>' && (pos += 1)
    atts, pos
end

# What one definition of an ATTLIST declares (rule [53]): the attribute's name, whether its type
# is other than CDATA, its keyword, and its default value as written between the quotes.
struct _AttDef
    name::String
    tokenized::Bool                     # a type other than CDATA (§3.3.1)
    keyword::Symbol                     # :required, :implied, :fixed, or :none for a plain default
    literal::Union{Nothing, String}
end

const _TOKENIZED_TYPES = ("ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS")

# An ATTLIST declaration read in full for the readers (rule [52]), from `pos` just past
# `<!ATTLIST`. Returns the element's name, its definitions in order, and the position after the
# closing `>`. The definitions are `nothing` when the declaration does not follow the grammar — a
# misspelled keyword, `#FIXED` without its value or the space before it, a default before its
# keyword, a parameter-entity reference — and the declaration is then skipped as a whole: no
# reading of a faulty declaration is a safe one. Unlike `_dtd_parse_attlist`, it never raises.
function _read_attlist(s::String, pos::Int)
    n = ncodeunits(s)
    skipped(p) = ("", nothing, _dtd_skip_to_close(s, p))
    p = _dtd_skip_ws(s, pos)
    p == pos && return skipped(p)
    element, p = _dtd_name_at(s, p)
    element === nothing && return skipped(p)
    defs = _AttDef[]
    while true
        q = _dtd_skip_ws(s, p)
        q > n && return skipped(q)
        s[q] == '>' && return (element, defs, nextind(s, q))
        q == p && return skipped(q)                      # each definition follows a space
        name, p = _dtd_name_at(s, q)
        name === nothing && return skipped(q)
        q = _dtd_skip_ws(s, p)
        (q == p || q > n) && return skipped(q)
        if s[q] == '('                                   # an enumeration
            p = _dtd_parens_end(s, q)
            tokenized = true
        else
            t, p = _dtd_name_at(s, q)
            if t == "NOTATION"
                q = _dtd_skip_ws(s, p)
                (q == p || q > n || s[q] != '(') && return skipped(q)
                p = _dtd_parens_end(s, q)
                tokenized = true
            elseif t == "CDATA"
                tokenized = false
            elseif t in _TOKENIZED_TYPES
                tokenized = true
            else
                return skipped(q)
            end
        end
        p === nothing && return skipped(q)
        q = _dtd_skip_ws(s, p)
        (q == p || q > n) && return skipped(q)
        literal = nothing
        if s[q] == '#'
            kw, p = _dtd_name_at(s, nextind(s, q))
            if kw == "REQUIRED" || kw == "IMPLIED"
                keyword = kw == "REQUIRED" ? :required : :implied
            elseif kw == "FIXED"
                q = _dtd_skip_ws(s, p)
                q == p && return skipped(q)
                literal, p = _dtd_literal_at(s, q)
                literal === nothing && return skipped(q)
                keyword = :fixed
            else
                return skipped(q)
            end
        else
            literal, p = _dtd_literal_at(s, q)
            literal === nothing && return skipped(q)
            keyword = :none
        end
        push!(defs, _AttDef(name, tokenized, keyword, literal))
    end
end

# A Name at `pos`, or `nothing` when none starts there.
function _dtd_name_at(s::String, pos::Int)
    start = pos
    while pos <= ncodeunits(s) && _dtd_is_name_char(s[pos])
        pos = nextind(s, pos)
    end
    pos == start ? (nothing, pos) : (String(SubString(s, start, prevind(s, pos))), pos)
end

# A quoted literal at `pos`: its content and the position after its closing quote, or `nothing`
# when no quote opens one there or it is never closed.
function _dtd_literal_at(s::String, pos::Int)
    (pos <= ncodeunits(s) && (s[pos] == '"' || s[pos] == '\'')) || return (nothing, pos)
    stop = findnext(s[pos], s, nextind(s, pos))
    stop === nothing && return (nothing, pos)
    String(SubString(s, nextind(s, pos), prevind(s, stop))), nextind(s, stop)
end

# The position after the `)` that closes the `(` at `pos`, or `nothing` when a `>` or the end
# comes first.
function _dtd_parens_end(s::String, pos::Int)
    depth = 0
    while pos <= ncodeunits(s)
        c = s[pos]
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return nextind(s, pos)
        elseif c == '>'
            return nothing
        end
        pos = nextind(s, pos)
    end
    nothing
end

# Parse `<!ENTITY [%] name "value">` or `<!ENTITY name SYSTEM/PUBLIC ...>`. `%` marks a
# parameter entity (referenced as `%name;` in DTDs only).
function _dtd_parse_entity(s, pos)
    pos = _dtd_skip_ws(s, pos)
    parameter = false
    if pos <= ncodeunits(s) && s[pos] == '%'
        parameter = true
        pos += 1
    end
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)

    value = nothing
    external_id = nothing
    if s[pos] == '"' || s[pos] == '\''
        v, pos = _dtd_read_quoted(s, pos)
        value = String(v)
    else
        keyword, pos = _dtd_read_name(s, pos)
        pos = _dtd_skip_ws(s, pos)
        if keyword == "SYSTEM"
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("SYSTEM \"", uri, "\"")
        elseif keyword == "PUBLIC"
            pubid, pos = _dtd_read_quoted(s, pos)
            pos = _dtd_skip_ws(s, pos)
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("PUBLIC \"", pubid, "\" \"", uri, "\"")
        else
            error("Expected SYSTEM, PUBLIC, or quoted value in ENTITY declaration")
        end
    end
    pos = _dtd_skip_to_close(s, pos)
    EntityDecl(String(name), value, external_id, parameter), pos
end

# Parse `<!NOTATION name SYSTEM "uri">` / `<!NOTATION name PUBLIC "pubid" ["uri"]>`.
function _dtd_parse_notation(s, pos)
    name, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    keyword, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)
    if keyword == "SYSTEM"
        uri, pos = _dtd_read_quoted(s, pos)
        external_id = string("SYSTEM \"", uri, "\"")
    elseif keyword == "PUBLIC"
        pubid, pos = _dtd_read_quoted(s, pos)
        pos = _dtd_skip_ws(s, pos)
        if pos <= ncodeunits(s) && (s[pos] == '"' || s[pos] == '\'')
            uri, pos = _dtd_read_quoted(s, pos)
            external_id = string("PUBLIC \"", pubid, "\" \"", uri, "\"")
        else
            external_id = string("PUBLIC \"", pubid, "\"")
        end
    else
        error("Expected SYSTEM or PUBLIC in NOTATION declaration")
    end
    pos = _dtd_skip_to_close(s, pos)
    NotationDecl(String(name), external_id), pos
end

"""
    parse_dtd(value::AbstractString) -> ParsedDTD
    parse_dtd(node::Node) -> ParsedDTD

Parse a DTD value string (from a `DTD` node) into structured declarations.
"""
# Public entry: parse a DTD value string into a structured `ParsedDTD`. Best-effort and
# non-validating — it does not expand parameter-entity references. On a parse failure, blame
# parameter entities only when the DTD actually contains a `%name;` reference; otherwise surface the
# underlying error (a bare '%' can appear legitimately in an entity value, comment, or system id).
const _PE_REF_RE = r"%[A-Za-z_:][A-Za-z0-9._:-]*;"

function parse_dtd(value::AbstractString)
    try
        return _parse_dtd_impl(value)
    catch e
        occursin(_PE_REF_RE, value) && error(
            "parse_dtd does not expand parameter-entity references (e.g. `%text;`); structured DTD " *
            "access is best-effort and non-validating, but the raw DTD node still round-trips " *
            "through write. (underlying parse error: " * sprint(showerror, e) * ")")
        rethrow(e)
    end
end

function _parse_dtd_impl(value::AbstractString)
    s = String(value)
    pos = 1

    root, pos = _dtd_read_name(s, pos)
    pos = _dtd_skip_ws(s, pos)

    # External ID
    system_id = nothing
    public_id = nothing
    if pos <= ncodeunits(s) && _dtd_is_name_char(s[pos])
        keyword, kpos = _dtd_read_name(s, pos)
        if keyword == "SYSTEM"
            pos = kpos
            uri, pos = _dtd_read_quoted(s, pos)
            system_id = String(uri)
        elseif keyword == "PUBLIC"
            pos = kpos
            pubid, pos = _dtd_read_quoted(s, pos)
            public_id = String(pubid)
            pos = _dtd_skip_ws(s, pos)
            if pos <= ncodeunits(s) && (s[pos] == '"' || s[pos] == '\'')
                uri, pos = _dtd_read_quoted(s, pos)
                system_id = String(uri)
            end
        end
    end

    elements = ElementDecl[]
    attributes = AttDecl[]
    entities = EntityDecl[]
    notations = NotationDecl[]

    # Internal subset
    pos = _dtd_skip_ws(s, pos)
    if pos <= ncodeunits(s) && s[pos] == '['
        pos += 1
        while pos <= ncodeunits(s)
            pos = _dtd_skip_ws(s, pos)
            pos > ncodeunits(s) && break
            s[pos] == ']' && break

            rest = SubString(s, pos)
            if startswith(rest, "<!--")
                i = findnext("-->", s, pos + 4)
                isnothing(i) && error("Unterminated comment in DTD")
                pos = last(i) + 1
            elseif startswith(rest, "<?")
                i = findnext("?>", s, pos + 2)
                isnothing(i) && error("Unterminated PI in DTD")
                pos = last(i) + 1
            elseif startswith(rest, "<!ELEMENT")
                elem, pos = _dtd_parse_element(s, pos + 9)
                push!(elements, elem)
            elseif startswith(rest, "<!ATTLIST")
                atts, pos = _dtd_parse_attlist(s, pos + 9)
                append!(attributes, atts)
            elseif startswith(rest, "<!ENTITY")
                ent, pos = _dtd_parse_entity(s, pos + 8)
                push!(entities, ent)
            elseif startswith(rest, "<!NOTATION")
                not, pos = _dtd_parse_notation(s, pos + 10)
                push!(notations, not)
            elseif s[pos] == '%'
                i = findnext(';', s, pos + 1)
                isnothing(i) && error("Unterminated parameter entity reference in DTD")
                pos = i + 1
            else
                pos += 1
            end
        end
    end

    ParsedDTD(String(root), system_id, public_id, elements, attributes, entities, notations)
end

function parse_dtd(node::Node)
    node.nodetype === DTD || error("parse_dtd requires a DTD node.")
    parse_dtd(node.value)
end

