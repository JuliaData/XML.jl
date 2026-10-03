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

# The declarations of the internal subset that the readers use, read in document order:
# `<!ENTITY name "value">` and `<!ATTLIST element …>`, the first declaration of a name binding
# (§4.2, §3.3). A reference to an internal parameter entity between two declarations is included
# (§4.4.8): the declarations its replacement text carries are read where the reference stands. A
# reference to one the processor has not read — external, or never declared — triggers §5.1's
# cutoff: the declarations that follow must not be used, unless the document is standalone,
# where they must. XML.jl reads no external parameter entity.

# What an ATTLIST declares for one attribute of an element: whether its values are reduced (a
# type other than CDATA, §3.3.3), and the text written for it when a tag leaves it out (§3.3.2).
struct _DeclaredAttr
    name::String
    normalize::Bool
    supplied::Union{Nothing, String}
end

mutable struct _SubsetReader
    const entities::Dict{String, String}     # general entities: name => replacement text
    const parameters::Dict{String, String}   # internal parameter entities: name => replacement text
    const attributes::Dict{String, Vector{_DeclaredAttr}}   # element => its attributes, in order
    const standalone::Bool
    const including::Vector{String}          # parameter entities being included, outermost first
    included::Int                            # bytes of replacement text read so far
    cut::Bool                                # §5.1's cutoff has been reached
end

function _subset_declarations(body::AbstractString, standalone::Bool = false)
    lb = findfirst('[', body)
    lb === nothing && return nothing
    s = String(body)
    r = _SubsetReader(Dict{String, String}(), Dict{String, String}(),
                      Dict{String, Vector{_DeclaredAttr}}(), standalone, String[], 0, false)
    _read_subset!(r, s, nextind(s, lb), true)
    r
end

# The first declaration of an attribute binds, type and default together, even when it supplies
# nothing (§3.3).
function _declare_attributes!(r::_SubsetReader, element::String, defs::Vector{_AttDef})
    declared = get!(() -> _DeclaredAttr[], r.attributes, element)
    for d in defs
        any(a -> a.name == d.name, declared) && continue
        supplied = d.literal === nothing ? nothing :
                   _supplied_text(d.literal, r.entities, d.tokenized)
        push!(declared, _DeclaredAttr(d.name, d.tokenized, supplied))
    end
end

# The text written for a supplied attribute: its default value with the references to entities
# declared so far — before the ATTLIST — included as in an attribute value (§4.4.5), and its
# quotes written as character references, so that it can stand between double quotes. Character
# references and the five predefined entities stay as written, for the readers to decode. A
# value of a type other than CDATA is written reduced, as a value written in a tag is (§3.3.3).
function _supplied_text(literal::String, entities::Dict{String, String}, tokenized::Bool)
    io = IOBuffer()
    ents = InternalEntities(entities, false)
    if tokenized
        _write_reduced!(io, literal, ents, UInt8('"'), 1)
    else
        _expand_refs!(io, literal, ents, 1, true)
    end
    String(take!(io))
end

# Reads `s` from `pos`: the internal subset itself, up to its `]`, or the replacement text of a
# parameter entity, to its end.
function _read_subset!(r::_SubsetReader, s::String, pos::Int, subset::Bool)
    n = ncodeunits(s)
    while pos <= n && !r.cut
        pos = _dtd_skip_ws(s, pos)
        pos > n && break
        c = s[pos]
        if c == ']' && subset
            break
        elseif c == '%'
            name, np = _dtd_read_name(s, nextind(s, pos))
            pos = np <= n && s[np] == ';' ? nextind(s, np) : np
            text = get(r.parameters, name, nothing)
            if text === nothing
                r.standalone || (r.cut = true)          # §5.1: an entity the processor has not read
            else
                name in r.including && error("not well-formed: parameter entity `%$name;` refers to " *
                    "itself (XML 1.0 well-formedness constraint: No Recursion), through " *
                    join([r.including; name], " -> "))
                length(r.including) >= _MAX_ENTITY_DEPTH &&
                    error("entity expansion exceeded $(_MAX_ENTITY_DEPTH) levels of nesting")
                r.included += ncodeunits(text)
                r.included > _MAX_ENTITY_EXPANSION &&
                    error("entity expansion exceeded $(_MAX_ENTITY_EXPANSION) bytes")
                push!(r.including, name)
                _read_subset!(r, text, 1, false)
                pop!(r.including)
            end
        elseif c == '<' && startswith(SubString(s, pos), "<!--")
            # A comment's text is free (§2.5): a quote in it opens no literal, and a `>` in it
            # ends nothing, so it is stepped over to its own `-->`
            stop = findnext("-->", s, pos + 4)
            stop === nothing && break
            pos = last(stop) + 1
        elseif c == '<' && startswith(SubString(s, pos), "<?")
            # and so is a processing instruction's (§2.6), to its `?>`
            stop = findnext("?>", s, pos + 2)
            stop === nothing && break
            pos = last(stop) + 1
        elseif c == '<' && startswith(SubString(s, pos), "<!ENTITY")
            decl, pos = _dtd_parse_entity(s, pos + ncodeunits("<!ENTITY"))
            # the replacement text is the literal with its character references resolved (§4.5);
            # an entity declared external has none, and for a parameter entity it is not read
            table = decl.parameter ? r.parameters : r.entities
            if decl.value !== nothing && !haskey(table, decl.name)
                table[decl.name] = _resolve_charrefs(decl.value)  # §4.2: the first declaration binds
            end
        elseif c == '<' && startswith(SubString(s, pos), "<!ATTLIST")
            element, defs, pos = _read_attlist(s, pos + ncodeunits("<!ATTLIST"))
            defs === nothing || _declare_attributes!(r, element, defs)
        elseif c == '<'
            pos = _dtd_skip_to_close(s, pos)                      # ELEMENT / NOTATION
        else
            pos = nextind(s, pos)
        end
    end
    pos
end

# Whether the XML declaration says `standalone="yes"` (§2.9). It is the prolog's first construct,
# so the first tokens settle it.
function _declares_standalone(xml::AbstractString)
    st = XMLTokenizer.tokenize(xml, 1)
    r = iterate(st)
    (r === nothing || r[1].kind !== XMLTokenizer.TokenKinds.XML_DECL_OPEN) && return false
    standalone = false
    for tok in st
        k = tok.kind
        k === XMLTokenizer.TokenKinds.XML_DECL_CLOSE && break
        if k === XMLTokenizer.TokenKinds.ATTR_NAME
            standalone = XMLTokenizer.raw(tok, xml) == "standalone"
        elseif k === XMLTokenizer.TokenKinds.ATTR_VALUE && standalone
            return XMLTokenizer.attr_value(tok, xml) == "yes"
        end
    end
    false
end

# A reference to a general entity, its name read as the tokenizer reads names: every non-ASCII
# character is a name character (§2.3).
const _GENREF_RE = r"&([A-Za-z_:[:^ascii:]][A-Za-z0-9._:[:^ascii:]-]*);"

# Well-formedness constraint "No Recursion" — a cycle is a termination hazard, refused at
# every `wellformed` level.
# The same walk answers whether any reachable replacement text carries a `<`.
function _check_and_scan(values::Dict{String, String})
    markup = false
    state = Dict{String, Int}()   # 0 = visiting, 1 = done
    function visit(name, chain)
        get(state, name, -1) == 1 && return
        haskey(state, name) && error("not well-formed: entity `$name` refers to itself " *
                                     "(XML 1.0 well-formedness constraint: No Recursion), through $(join(chain, " -> "))")
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
    _declarations(xml) -> Union{Nothing, _Declarations}

What the document's internal subset declares that the entry rewrite applies: its general
entities, and the attributes that ask for work, by element — a value to supply or to reduce.
`nothing` when it declares neither, the case that must cost nothing beyond the prolog walk.
"""
struct _Declarations
    entities::Union{Nothing, InternalEntities}
    attributes::Union{Nothing, Dict{String, Vector{_DeclaredAttr}}}
end

function _declarations(xml::AbstractString)
    _has_doctype(xml) || return nothing
    body = _doctype_body(xml)
    body === nothing && return nothing
    r = _subset_declarations(body, _declares_standalone(xml))
    r === nothing && return nothing
    ents = isempty(r.entities) ? nothing : InternalEntities(r.entities, _check_and_scan(r.entities))
    attrs = _working_attributes(r.attributes)
    ents === nothing && attrs === nothing && return nothing
    _Declarations(ents, attrs)
end

# The declared attributes that ask for work; an attribute declared CDATA with no default asks
# for none, and an element left with none is dropped, so that a walk looks up only what counts.
function _working_attributes(declared::Dict{String, Vector{_DeclaredAttr}})
    out = nothing
    for (element, attrs) in declared
        work = filter(a -> a.normalize || a.supplied !== nothing, attrs)
        isempty(work) && continue
        out === nothing && (out = Dict{String, Vector{_DeclaredAttr}}())
        out[element] = work
    end
    out
end

"""
    _internal_entities(xml) -> Union{Nothing, InternalEntities}

The general entities the document's internal subset declares, or `nothing` when it declares
none.
"""
_internal_entities(xml::AbstractString) = (d = _declarations(xml); d === nothing ? nothing : d.entities)

#-----------------------------------------------------------------------------# inclusion (§4.4.2)
# Nested declarations amplify without any cycle — ten entities each naming the previous one ten
# times reach 10^10 bytes at depth ten — so the No Recursion constraint is not enough and expansion carries
# its own bounds. Both are refused at every `wellformed` level: an unbounded expansion is a
# termination hazard, not a conformance question.
const _MAX_ENTITY_DEPTH = 40
const _MAX_ENTITY_EXPANSION = 64 * 1024 * 1024   # bytes an expanded document may reach

# A reference to a declared general entity is replaced by its replacement text, and that text's
# own references with it (§4.4.2). Everything else is copied through untouched — a character
# reference, one of the five predefined entities, an undeclared name: the parser reads those
# afterwards, from the document this pass writes. §4.5 bypasses references when the declaration
# is read, so bypassing them again here is what makes `&amp;` in a replacement text arrive at the
# parser as `&amp;` and reach the application as `&`.
#
# Unlike the line-end rewrite, whose output is bounded by its source, an expansion's length is
# not known until it ends — amplification is the point of the bounds above. A growable buffer is
# therefore the right shape here, where a sized one was right there.
#
# A name is read as the tokenizer reads names (`XMLTokenizer.NAME_BYTE_TABLE`): ASCII name
# characters, and every byte of a non-ASCII character (§2.3). `#` passes too, so a character
# reference reads as a name that no declaration binds, and is copied through.
@inline _is_name_byte(b::UInt8) = XMLTokenizer.is_name_byte(b) || b == UInt8('#')

# §4.4.5 Included in Literal: when the reference stands in an attribute value, the quotation
# marks of the replacement text "are not recognized as delimiters". A pass that writes into the
# document has to say so: a quote is written back as a character reference, which the parser
# decodes to the quote it stood for. `<` is left alone on purpose — it is illegal in an attribute
# value (§3.1), and leaving it lets the parser report that rather than this pass hiding it.
@inline function _write_literal(io::IOBuffer, c::AbstractChar, literal::Bool)
    if literal && (c == '"' || c == '\'')
        Base.write(io, c == '"' ? "&#34;" : "&#39;")
    else
        Base.write(io, c)
    end
end

# §3.3.3 reads each white space character of an attribute value as one space. The readers do
# that for the value as written, with the CR LF pair already one line end (§2.11); a character
# that comes from an entity's text is written here as the space it reads as, so that a CR LF
# pair there gives two spaces (W3C valid-sa-110). `entity` says the span is an entity's text.
function _write_span!(io::IOBuffer, s::AbstractString, literal::Bool, entity::Bool = false)
    literal || return Base.write(io, s)
    for c in s
        _write_literal(io, entity && (c == '\t' || c == '\n' || c == '\r') ? ' ' : c, true)
    end
end

# `depth` is the nesting level of `s`: 1 for the document's own text, one more for each entity
# its text comes through. In content, given the declarations `d`, a replacement text that
# carries a `<` is read as markup by `_rewrite_walk!` (§4.4.2), so that the tags it brings are
# rewritten as written ones are; any other is included as text.
function _expand_refs!(io::IOBuffer, s::AbstractString, ents::InternalEntities, depth::Int,
                       literal::Bool = false, d::Union{Nothing, _Declarations} = nothing)
    depth > _MAX_ENTITY_DEPTH &&
        error("entity expansion exceeded $(_MAX_ENTITY_DEPTH) levels of nesting")
    i = firstindex(s)
    stop = lastindex(s)
    while i <= stop
        amp = findnext('&', s, i)
        if amp === nothing
            _write_span!(io, SubString(s, i), literal, depth > 1)
            break
        end
        amp > i && _write_span!(io, SubString(s, i, prevind(s, amp)), literal, depth > 1)
        j = nextind(s, amp)
        while j <= stop && _is_name_byte(codeunit(s, j))
            j = nextind(s, j)
        end
        if j > stop || codeunit(s, j) != UInt8(';') || j == nextind(s, amp)
            Base.write(io, '&')                      # not a reference: a literal ampersand
            i = nextind(s, amp)
            continue
        end
        name = SubString(s, nextind(s, amp), prevind(s, j))
        rep = get(ents.values, name, nothing)
        if rep === nothing
            Base.write(io, SubString(s, amp, j))
        elseif !literal && d !== nothing && occursin('<', rep)
            _rewrite_walk!(io, rep, d, depth + 1, name)
        else
            _expand_refs!(io, rep, ents, depth + 1, literal, d)
        end
        io.size > _MAX_ENTITY_EXPANSION &&
            error("entity expansion exceeded $(_MAX_ENTITY_EXPANSION) bytes")
        i = nextind(s, j)
    end
    io
end

#-----------------------------------------------------------------------------# reduction (§3.3.3)
# A value of a type other than CDATA is reported with its spaces reduced: none at either end, one
# for each run. Only #x20 counts. Each white space character reads as one, whether the value
# writes it or an entity's text does, and so does a reference to #x20; `&#9;` and `&#10;` stand
# for characters that are kept (W3C valid-sa-058, 096, 111). The rewrite writes the reduced
# value back in a form the readers report unchanged: a space as a space, any other reference as
# it stands, for them to decode.

# The `;` of the character reference at `i`, where `cu[i]` is `&`, when it stands for #x20, or
# 0. It is read by the readers' own lexer, so a reference counts as a space exactly where they
# would decode one.
@inline function _space_ref_end(cu, i::Int, n::Int)
    (i + 1 <= n && cu[i + 1] == UInt8('#')) || return 0
    j, cp = _charref_at(cu, i, n)
    cp == 0x00000020 ? j : 0
end

@inline _replacement(::Nothing, name::AbstractString) = nothing
@inline _replacement(e::InternalEntities, name::AbstractString) = get(e.values, name, nothing)

# Whether the reduction changes a value's bytes: white space other than single spaces within it,
# a reference to #x20, or a reference to a declared entity. Answered without writing, so that a
# document whose values are already reduced is walked without a copy.
function _changes_when_reduced(s::AbstractString, ents::Union{Nothing, InternalEntities})
    cu = codeunits(s)
    n = length(cu)
    space = true                                     # a space here would be a leading one
    for i in 1:n
        b = cu[i]
        if b == UInt8(' ')
            space && return true                     # leading, or the second of a run
            space = true
        elseif b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')
            return true
        else
            space = false
            if b == UInt8('&')
                _space_ref_end(cu, i, n) > 0 && return true
                j = _name_end(cu, i + 1, n)
                j > 0 && _replacement(ents, SubString(s, i + 1, prevind(s, j))) !== nothing &&
                    return true
            end
        end
    end
    space && n > 0                                   # a trailing space
end

# Writes `s` reduced. A reference to a declared entity is replaced by its text, reduced the same
# way and with the value around it: a space that ends the text and one that follows it make one
# run. Any other byte is written as it stands, a reference included, for the readers to decode;
# a quote that would close the value (`q`) is written as a character reference (§4.4.5).
# Returns whether something has been written, and whether a space waits for what follows.
function _write_reduced!(io::IOBuffer, s::AbstractString, ents::Union{Nothing, InternalEntities},
                         q::UInt8, depth::Int, started::Bool = false, pending::Bool = false)
    depth > _MAX_ENTITY_DEPTH &&
        error("entity expansion exceeded $(_MAX_ENTITY_DEPTH) levels of nesting")
    cu = codeunits(s)
    n = length(cu)
    i = 1
    while i <= n
        b = cu[i]
        if b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')
            pending = started                        # written only if something follows
            i += 1
            continue
        elseif b == UInt8('&')
            j = _space_ref_end(cu, i, n)
            if j > 0
                pending = started
                i = j + 1
                continue
            end
            j = _name_end(cu, i + 1, n)
            rep = j > 0 ? _replacement(ents, SubString(s, i + 1, prevind(s, j))) : nothing
            if rep !== nothing
                started, pending =
                    _write_reduced!(io, rep, ents, q, depth + 1, started, pending)
                io.size > _MAX_ENTITY_EXPANSION &&
                    error("entity expansion exceeded $(_MAX_ENTITY_EXPANSION) bytes")
                i = j + 1
                continue
            end
        end
        pending && Base.write(io, UInt8(' '))
        pending = false
        started = true
        b == q ? Base.write(io, q == UInt8('"') ? "&#34;" : "&#39;") : Base.write(io, b)
        i += 1
    end
    started, pending
end

# Whether a span holds a reference to a name the subset declares — the test that decides whether
# it is rewritten at all, so that a document declaring entities it never uses is copied verbatim.
function _references_declared(s::AbstractString, ents::InternalEntities)
    i = firstindex(s)
    stop = lastindex(s)
    while (amp = findnext('&', s, i)) !== nothing
        j = nextind(s, amp)
        while j <= stop && _is_name_byte(codeunit(s, j))
            j = nextind(s, j)
        end
        j <= stop && codeunit(s, j) == UInt8(';') &&
            haskey(ents.values, SubString(s, nextind(s, amp), prevind(s, j))) && return true
        i = nextind(s, amp)
    end
    false
end

"""
    _apply_declarations(src) -> src, or a rewritten copy of the same type

The entry rewrite the four readers share: the document is rewritten once, before any reader
reads it, so that what the internal subset declares applies the same way in all four. XML 1.0
§4.4.2 includes a general entity's replacement text "as though it were part of the document at
the location the reference was recognized" — so a reference whose replacement text carries
markup produces STRUCTURE, not a text node holding `<`: the parser reads the rewritten document
and builds the nodes itself.

Only content and attribute values are rewritten. A reference inside a comment, a CDATA section,
a processing instruction or the internal subset is not a reference (§4.4.2 recognises them in
content and in attribute values), so those spans are copied byte for byte.

A document that declares nothing costs one probe of its prolog and is returned as it stands, and
so is one whose walk changes nothing: no copy is made. A rewritten document comes back as the
type the reader was given (`_rebuild_source`); a source of a type that cannot be rebuilt
is refused with an `ArgumentError`, only when its document needs the rewrite.
"""
function _apply_declarations(s::AbstractString)
    d = _declarations(s)
    d === nothing && return s
    bytes = _rewritten_bytes(s, d)
    bytes === nothing && return s
    rebuilt = _rebuild_source(s, bytes)
    rebuilt === nothing && _unrebuildable(s)
    rebuilt
end

@noinline _unrebuildable(s::AbstractString) = throw(ArgumentError(
    "XML.jl cannot apply this document's DTD declarations to a source held as $(typeof(s)); " *
    "pass it as a String, or as a StringView over a Vector{UInt8}"))

"""
    _rebuild_source(src, bytes) -> a source of `src`'s own type, or `nothing`

The rewrite produces bytes; this returns them as the type the reader was given, so a reader's
type parameter is the same whether or not the document declared anything. Each method returns
one concrete type, and the fallback returns `nothing`, which `_apply_declarations` turns into an
`ArgumentError`: either way its result is the argument's own type, for every source type.

An extension supplies the methods for `StringView`, and is loaded whenever a `StringView` can
exist at all, since the type comes from the package that extension names.
"""
_rebuild_source(::AbstractString, ::Vector{UInt8}) = nothing
_rebuild_source(::String, bytes::Vector{UInt8}) = String(bytes)
_rebuild_source(::SubString{String}, bytes::Vector{UInt8}) = SubString(String(bytes))

# One walk of the document: spans that need no work are copied, references to declared names are
# expanded, the value of an attribute declared with a type other than CDATA is written reduced
# (§3.3.3), and a start tag of a declared element receives, just before its `>` or `/>`, each
# attribute it leaves out that a default supplies (§3.3.2), after the ones it writes. Returns
# `nothing` when nothing was rewritten, so the caller returns its own argument instead of an equal
# copy; the output buffer is created at the first change, so a walk that changes nothing
# allocates none.
function _rewritten_bytes(s::AbstractString, d::_Declarations)
    out = _rewrite_walk!(nothing, s, d, 1)
    out === nothing ? nothing : take!(out)
end

# The walk itself, over the document (`depth` 1) or over the replacement text of an entity
# included in content that carries markup (`depth` > 1), which it reads the same way: the tags
# that text brings receive their defaults and reduction, and a reference in one of their values
# is included in literal. Every character of such a value is an entity's, so its white space
# reads as spaces even where it names no entity. The text must be balanced content (§4.3.2).
function _rewrite_walk!(out::Union{Nothing, IOBuffer}, s::AbstractString, d::_Declarations,
                        depth::Int, entity::AbstractString = "")
    fragment = depth > 1
    if fragment
        depth > _MAX_ENTITY_DEPTH &&
            error("entity expansion exceeded $(_MAX_ENTITY_DEPTH) levels of nesting")
        _is_balanced(s) || _unbalanced(entity)
    end
    ents = d.entities
    attrs = d.attributes
    # Token offsets are root-relative, so a source that is itself a view over a larger string
    # reports positions past its own start; subtracting its offset returns them to the index
    # space of `s`, which is what the copied spans below are indexed in.
    base = XMLTokenizer._data_offset(s)
    pos = 1                                          # 1-based byte position of the next byte to copy
    current = nothing                                # the declared attributes of the open start tag
    written = Bool[]                                 # which of them the tag writes
    reduce_value = false                             # the next value is of a type other than CDATA
    for tok in XMLTokenizer.tokenize(s, 1)
        k = tok.kind
        if k === XMLTokenizer.TokenKinds.OPEN_TAG
            attrs === nothing && continue
            current = get(attrs, XMLTokenizer.tag_name(tok, s), nothing)
            current === nothing && continue
            resize!(written, length(current))
            fill!(written, false)
            continue
        elseif k === XMLTokenizer.TokenKinds.ATTR_NAME
            reduce_value = false
            current === nothing && continue
            name = XMLTokenizer.raw(tok, s)
            for i in eachindex(current)
                current[i].name == name || continue
                written[i] = true
                reduce_value = current[i].normalize
            end
            continue
        elseif k === XMLTokenizer.TokenKinds.ATTR_VALUE && reduce_value
            reduce_value = false
            span = XMLTokenizer.raw(tok, s)
            inner = SubString(span, nextind(span, firstindex(span)),
                              prevind(span, lastindex(span)))
            _changes_when_reduced(inner, ents) || continue
            start = tok.offset - base + 1
            out === nothing && (out = IOBuffer(sizehint = ncodeunits(s)))
            Base.write(out, SubString(s, pos, prevind(s, start)))
            q = codeunit(span, 1)
            Base.write(out, q)
            _write_reduced!(out, inner, ents, q, depth)
            Base.write(out, q)
            pos = start + tok.ncodeunits
            continue
        elseif k === XMLTokenizer.TokenKinds.TAG_CLOSE || k === XMLTokenizer.TokenKinds.SELF_CLOSE
            current === nothing && continue
            start = tok.offset - base + 1
            for i in eachindex(current)
                a = current[i]
                (written[i] || a.supplied === nothing) && continue
                out === nothing && (out = IOBuffer(sizehint = ncodeunits(s)))
                Base.write(out, SubString(s, pos, prevind(s, start)))
                Base.write(out, ' ', a.name, "=\"", a.supplied, '"')
                pos = start
            end
            current = nothing
            continue
        end
        ents === nothing && continue
        (k === XMLTokenizer.TokenKinds.TEXT || k === XMLTokenizer.TokenKinds.ATTR_VALUE) || continue
        span = XMLTokenizer.raw(tok, s)
        if !(tok.has_entities && _references_declared(span, ents))
            # nothing to include; in a replacement text a value is still rewritten for its
            # white space
            (fragment && k === XMLTokenizer.TokenKinds.ATTR_VALUE && _attr_ws_dirty(span)) ||
                continue
        end
        start = tok.offset - base + 1
        out === nothing && (out = IOBuffer(sizehint = ncodeunits(s)))
        Base.write(out, SubString(s, pos, prevind(s, start)))
        if tok.kind === XMLTokenizer.TokenKinds.ATTR_VALUE
            # the span carries its delimiters; only what they enclose is expanded, in literal
            q = span[firstindex(span)]
            Base.write(out, q)
            _expand_refs!(out, SubString(span, nextind(span, firstindex(span)), prevind(span, lastindex(span))),
                          ents, depth, true)
            Base.write(out, q)
        else
            _expand_refs!(out, span, ents, depth, false, d)
        end
        pos = start + tok.ncodeunits
    end
    out === nothing && return nothing
    pos <= ncodeunits(s) && Base.write(out, SubString(s, pos))
    out
end

# Whether a replacement text is balanced content (§4.3.2): every element it opens is closed
# within it, it closes none it did not open, and it ends outside any tag. A tag cut at its end
# either stops the tokenizer at the cut, or raises its `ArgumentError`: both are a no.
function _is_balanced(s::AbstractString)
    level = 0
    start_tag = false                                # inside a start tag
    end_tag = false                                  # inside an end tag
    try
        for tok in XMLTokenizer.tokenize(s, 1)
            k = tok.kind
            if k === XMLTokenizer.TokenKinds.OPEN_TAG
                start_tag = true
            elseif k === XMLTokenizer.TokenKinds.CLOSE_TAG
                level -= 1
                level < 0 && return false
                end_tag = true
            elseif k === XMLTokenizer.TokenKinds.TAG_CLOSE
                start_tag && (level += 1)
                start_tag = end_tag = false
            elseif k === XMLTokenizer.TokenKinds.SELF_CLOSE
                start_tag = false
            end
        end
    catch e
        e isa ArgumentError || rethrow()
        return false
    end
    level == 0 && !start_tag && !end_tag
end

@noinline _unbalanced(name::AbstractString) = error("not well-formed: the replacement text of " *
    "entity \"$name\" is not balanced content (XML 1.0 §4.3.2)")

"""
    _entity_wfc_applies(xml) -> Bool

XML 1.0 §4.1's well-formedness constraint "Entity Declared" binds a processor only where a
missing name is certain, which needs every declaration the document has to be one this reader
sees. Two shapes qualify. A document with no DTD has none to miss. A DOCTYPE qualifies when
its declarations all sit in the internal subset and nothing points outside it: no external
subset named by SYSTEM or PUBLIC, no parameter-entity reference — which could expand into
further declarations — and no entity declared as external, whose replacement text is in
another file. Under any other shape a declaration this reader never reads could supply the
name, so a name it does not know is not a defect.

The specification also binds the constraint under `standalone="yes"` even with external parts.
`false` there means a missed rejection and never a wrong one, which is the direction to err in.
"""
function _entity_wfc_applies(xml::AbstractString)
    body = _doctype_body(xml)
    body === nothing && return true
    # One test covers both shapes that put a declaration out of reach: an external subset named
    # in the DOCTYPE head, and an external entity declared inside the internal subset.
    occursin(r"\bSYSTEM\b|\bPUBLIC\b", body) && return false
    lb = findfirst('[', body)
    lb === nothing && return true
    !occursin('%', SubString(body, lb))
end
