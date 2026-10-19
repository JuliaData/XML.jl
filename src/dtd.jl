#-----------------------------------------------------------------------------# DTD parsing
struct EntityDecl
    name::String
    value::Union{Nothing, String}       # replacement text (internal entities)
    external_id::Union{Nothing, String} # "SYSTEM \"uri\"" or "PUBLIC \"pubid\" \"uri\""
    parameter::Bool
end

# DTD parsing helpers — each returns (parsed_piece, new_pos) so calls compose.

# A character that can appear in an XML Name (letters, digits, `_`, `-`, `.`, `:`, and any
# non-ASCII char — mirrors the tokenizer's lenient NAME_BYTE_TABLE rule).
@inline _dtd_is_name_char(c::Char) =
    ('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') ||
    c == '_' || c == '-' || c == '.' || c == ':' || !isascii(c)

# One step forward, tolerant of running past the end: each reader tests `pos <= ncodeunits`
# before it indexes, so a step beyond the last character only has to keep the loop terminating.
@inline _dtd_next(s, pos) = pos <= ncodeunits(s) ? nextind(s, pos) : pos + 1

# The DTD readers walk a String by index, so every step goes through `nextind`: a `pos + 1`
# lands inside a character as soon as the subset holds one that is not ASCII — in a comment,
# an entity value or a name — and indexing there throws.
# Advance past any whitespace.
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
# reading of a faulty declaration is a safe one. It never raises.
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
