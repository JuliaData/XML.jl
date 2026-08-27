#-----------------------------------------------------------------------------# internal general entities
# XML 1.0 §4.4: a reference to a general entity declared in the internal subset is *included* —
# its replacement text is processed in place of the reference. §5.1 makes that a requirement of
# non-validating processors too, so the readers need the declarations the internal subset carries.
#
# Replacement text is built per §4.5: character references resolve when the declaration is read,
# general-entity references are BYPASSED and expand at each use. That distinction is what
# `markup` below turns on — `&#60;` in a declaration is already a `<` and can open an element,
# while `&e;` is still a reference.

"""
The general entities a document's internal subset declares, with the one bit that decides how
inclusion can be implemented: `markup` is true when some replacement text, once character
references resolve and nested references expand, carries a `<`. Without it every reference is a
text substitution; with it, inclusion has to produce structure.
"""
struct InternalEntities
    values::Dict{String, String}   # name => replacement text, first declaration binding (§4.2)
    markup::Bool
end

Base.isempty(e::InternalEntities) = isempty(e.values)

# Character references resolve into the replacement text at declaration time (§4.5); general
# references do not. `&#60;` therefore counts as markup where `&lt;` does not — the latter is a
# predefined entity, bypassed like any other reference and reported as a literal `<` in a value.
const _CHARREF_RE = r"&#(?:[0-9]+|[xX][0-9a-fA-F]+);"

_resolve_charrefs(v::AbstractString) = occursin('&', v) ? replace(v, _CHARREF_RE => _unescape_entity) : v

# Whether the prolog may hold a DOCTYPE, decided without producing a token. Before the DOCTYPE
# or the root element a prolog admits only white space, the XML declaration, comments and
# processing instructions (§2.8), so three forms and a byte search over each settle it.
#
# The answer only decides whether `_doctype_body` is worth running, and the two costs are not
# symmetric: saying yes wrongly wastes a prolog walk, saying no wrongly leaves entities
# unexpanded with nothing to show for it. So `false` is returned only on positive knowledge —
# the root element was reached — and anything unrecognised defers to the tokenizer. A
# differential test pins the pair over every fixture on disk.
@inline function _has_doctype(s::AbstractString)
    n = ncodeunits(s)
    i = 1
    startswith(s, '﻿') && (i = nextind(s, 1))
    @inbounds while i <= n
        b = codeunit(s, i)
        if b == UInt8(' ') || b == UInt8('\n') || b == UInt8('\t') || b == UInt8('\r')
            i += 1
            continue
        end
        b == UInt8('<') || return true               # not a prolog we recognise: let it decide
        i + 1 > n && return false
        c = codeunit(s, i + 1)
        if c == UInt8('?')                           # the XML declaration, or a PI
            j = findnext("?>", s, i)
            j === nothing && return false
            i = last(j) + 1
        elseif c == UInt8('!')
            if i + 3 <= n && codeunit(s, i + 2) == UInt8('-') && codeunit(s, i + 3) == UInt8('-')
                j = findnext("-->", s, i)            # a comment
                j === nothing && return false
                i = last(j) + 1
            else
                return true                          # `<!DOCTYPE`, or something only the tokenizer reads
            end
        else
            return false                             # the root element: the prolog is over
        end
    end
    false
end

# The prolog is walked, not the document: a DOCTYPE precedes the root element, so tokenizing
# stops at the first open tag. A document without one costs that walk and nothing more.
function _doctype_body(xml::AbstractString)
    st = XMLTokenizer.tokenize(xml, 1)
    while true
        r = iterate(st)
        r === nothing && return nothing
        tok, _ = r
        k = tok.kind
        k === XMLTokenizer.TokenKinds.DOCTYPE_CONTENT && return XMLTokenizer.raw(tok, xml)
        k === XMLTokenizer.TokenKinds.OPEN_TAG && return nothing
    end
end

# `<!ENTITY name "value">` declarations of the internal subset, in document order. Parameter
# entities are skipped, and §5.1's cutoff applies: once a reference to a parameter entity the
# processor has not read appears, the declarations that follow must not be used. XML.jl reads no
# external parameter entities, so the cutoff is the first reference to one it did not declare.
function _subset_entities(body::AbstractString)
    lb = findfirst('[', body)
    lb === nothing && return nothing
    s = String(body)
    pos = nextind(s, lb)
    n = ncodeunits(s)
    out = Dict{String, String}()
    declared_pe = Set{String}()
    while pos <= n
        pos = _dtd_skip_ws(s, pos)
        pos > n && break
        c = s[pos]
        if c == ']'
            break
        elseif c == '%'
            # a parameter-entity reference between declarations: §5.1 cutoff unless we read it
            name, np = _dtd_read_name(s, nextind(s, pos))
            name in declared_pe || break
            pos = np <= n && s[np] == ';' ? nextind(s, np) : np
        elseif c == '<' && startswith(SubString(s, pos), "<!ENTITY")
            decl, pos = _dtd_parse_entity(s, pos + ncodeunits("<!ENTITY"))
            if decl.parameter
                decl.value === nothing || push!(declared_pe, decl.name)
            elseif decl.value !== nothing && !haskey(out, decl.name)
                out[decl.name] = _resolve_charrefs(decl.value)   # §4.2: the first declaration binds
            end
        elseif c == '<'
            pos = _dtd_skip_to_close(s, pos)                     # ELEMENT / ATTLIST / NOTATION / comment
        else
            pos = nextind(s, pos)
        end
    end
    isempty(out) ? nothing : out
end

const _GENREF_RE = r"&([A-Za-z_:][A-Za-z0-9._:-]*);"
const _PREDEFINED = ("amp", "lt", "gt", "apos", "quot")

# WFC: No Recursion — a cycle is a termination hazard, refused at every `wellformed` level.
# The same walk answers whether any reachable replacement text carries a `<`.
function _check_and_scan(values::Dict{String, String})
    markup = false
    state = Dict{String, Int}()   # 0 = visiting, 1 = done
    function visit(name, chain)
        get(state, name, -1) == 1 && return
        haskey(state, name) && error("not well-formed: entity `$name` refers to itself " *
                                     "(XML 1.0 WFC: No Recursion), through $(join(chain, " -> "))")
        state[name] = 0
        v = values[name]
        occursin('<', v) && (markup = true)
        for m in eachmatch(_GENREF_RE, v)
            ref = m.captures[1]
            ref in _PREDEFINED && continue
            haskey(values, ref) && visit(ref, [chain; ref])
        end
        state[name] = 1
    end
    for name in sort!(collect(keys(values)))
        visit(name, [name])
    end
    markup
end

"""
    _internal_entities(xml) -> Union{Nothing, InternalEntities}

The general entities the document's internal subset declares, or `nothing` when it declares
none — the case that must cost nothing beyond the prolog walk.
"""
function _internal_entities(xml::AbstractString)
    _has_doctype(xml) || return nothing
    body = _doctype_body(xml)
    body === nothing && return nothing
    values = _subset_entities(body)
    values === nothing && return nothing
    InternalEntities(values, _check_and_scan(values))
end

#-----------------------------------------------------------------------------# inclusion (§4.4.2)
# Nested declarations amplify without any cycle — ten entities each naming the previous one ten
# times reach 10^10 bytes at depth ten — so WFC: No Recursion is not enough and expansion carries
# its own bounds. Both are refused at every `wellformed` level: an unbounded expansion is a
# termination hazard, not a conformance question.
const _MAX_ENTITY_DEPTH = 40
const _MAX_ENTITY_EXPANSION = 10 * 1024 * 1024   # bytes produced from one reported value

# A reference is recognised once, in the text as it stands, and dispatched on what it names: a
# character reference or one of the five predefined entities decodes to its character, a declared
# general entity is INCLUDED with its own references expanded in turn (§4.4.2), and anything else
# is copied through — today's graceful degradation for an undeclared name. Resolving the
# predefined ones in an earlier separate pass would be wrong: it manufactures `&` bytes that the
# later pass would read as references nobody wrote.
@inline _is_name_byte(b::UInt8) =
    (b >= UInt8('a') && b <= UInt8('z')) || (b >= UInt8('A') && b <= UInt8('Z')) ||
    (b >= UInt8('0') && b <= UInt8('9')) || b == UInt8('_') || b == UInt8(':') ||
    b == UInt8('.') || b == UInt8('-') || b == UInt8('#')

function _expand_into!(io::IOBuffer, s::AbstractString, ents::InternalEntities, depth::Int)
    depth > _MAX_ENTITY_DEPTH &&
        error("entity expansion exceeded $(_MAX_ENTITY_DEPTH) levels of nesting")
    i = firstindex(s)
    stop = lastindex(s)
    while i <= stop
        amp = findnext('&', s, i)
        if amp === nothing
            Base.write(io, SubString(s, i))
            break
        end
        amp > i && Base.write(io, SubString(s, i, prevind(s, amp)))
        # the name runs while its bytes can belong to one; a stray `&` ends the scan at once
        j = nextind(s, amp)
        while j <= stop && _is_name_byte(codeunit(s, j))
            j = nextind(s, j)
        end
        if j > stop || codeunit(s, j) != UInt8(';') || j == nextind(s, amp)
            Base.write(io, '&')                         # not a reference: a literal ampersand
            i = nextind(s, amp)
            continue
        end
        name = SubString(s, nextind(s, amp), prevind(s, j))
        rep = get(ents.values, name, nothing)
        if rep === nothing
            Base.write(io, _unescape_entity(SubString(s, amp, j)))
        else
            _expand_into!(io, rep, ents, depth + 1)
        end
        io.size > _MAX_ENTITY_EXPANSION &&
            error("entity expansion exceeded $(_MAX_ENTITY_EXPANSION) bytes")
        i = nextind(s, j)
    end
    io
end

# The two decode strategies a reader can carry. The choice is made once, at the document entry,
# and reaches the value accessors as a type — not as a field they test — so a document with no
# internal general entities runs the same code it runs today. `NoEntities` is zero-size, so it
# also leaves the readers' layout untouched.
struct NoEntities end

struct WithEntities
    ents::InternalEntities
end

@inline (::NoEntities)(x::AbstractString) = unescape(x)

function (d::WithEntities)(x::AbstractString)
    occursin('&', x) || return x
    String(take!(_expand_into!(IOBuffer(), x, d.ents, 1)))
end
