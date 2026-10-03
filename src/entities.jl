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

# What `:strict` needs from the subset beyond what the readers use (§4.1, §3.1): whether a
# parameter-entity reference stands between two declarations, the general entities in the order
# they are declared, the external and unparsed ones apart, and each default value with the
# number of general entities declared before it.
mutable struct _StrictRecord
    pe_refs::Bool
    const order::Dict{String, Int}           # general entity => rank, first declaration binding
    const external::Set{String}
    const unparsed::Set{String}
    const defaults::Vector{Tuple{String, String, String, Int}}   # element, attribute, literal, rank
end
_StrictRecord() = _StrictRecord(false, Dict{String, Int}(), Set{String}(), Set{String}(),
                                Tuple{String, String, String, Int}[])

mutable struct _SubsetReader
    const entities::Dict{String, String}     # general entities: name => replacement text
    const parameters::Dict{String, String}   # internal parameter entities: name => replacement text
    const attributes::Dict{String, Vector{_DeclaredAttr}}   # element => its attributes, in order
    const standalone::Bool
    const including::Vector{String}          # parameter entities being included, outermost first
    included::Int                            # bytes of replacement text read so far
    cut::Bool                                # §5.1's cutoff has been reached
    const strict::Union{Nothing, _StrictRecord}   # filled only when `:strict` reads the subset
end

function _subset_declarations(body::AbstractString, standalone::Bool = false,
                              strict::Union{Nothing, _StrictRecord} = nothing)
    lb = findfirst('[', body)
    lb === nothing && return nothing
    s = String(body)
    r = _SubsetReader(Dict{String, String}(), Dict{String, String}(),
                      Dict{String, Vector{_DeclaredAttr}}(), standalone, String[], 0, false, strict)
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
            r.strict === nothing || (r.strict.pe_refs = true)
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
            start = pos
            decl, pos = _dtd_parse_entity(s, pos + ncodeunits("<!ENTITY"))
            # the replacement text is the literal with its character references resolved (§4.5);
            # an entity declared external has none, and for a parameter entity it is not read
            table = decl.parameter ? r.parameters : r.entities
            if decl.value !== nothing && !haskey(table, decl.name)
                table[decl.name] = _resolve_charrefs(decl.value)  # §4.2: the first declaration binds
            end
            r.strict === nothing || decl.parameter || _record_entity!(r.strict, decl, s, start, pos)
        elseif c == '<' && startswith(SubString(s, pos), "<!ATTLIST")
            element, defs, pos = _read_attlist(s, pos + ncodeunits("<!ATTLIST"))
            defs === nothing || _declare_attributes!(r, element, defs)
            if r.strict !== nothing && defs !== nothing
                rank = length(r.strict.order)
                for d in defs
                    d.literal === nothing ||
                        push!(r.strict.defaults, (element, d.name, d.literal, rank))
                end
            end
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
# allocates none. A DTD that declares no general entity leaves nothing in content to rewrite:
# the walk over start tags alone then does the same work in less time.
function _rewritten_bytes(s::AbstractString, d::_Declarations)
    if d.entities === nothing
        done, bytes = _rewrite_tags(s, d.attributes)
        done && return bytes
    end
    out = _rewrite_walk!(nothing, s, d, 1)
    out === nothing ? nothing : take!(out)
end

# The walk over start tags, for a DTD that declares attributes and no general entity. The bytes
# between two tags are stepped over by a search for `<`; a comment, a CDATA section and a
# processing instruction to their ends; the start tag of an element the table does not name to
# its `>`, past its quoted values. A start tag of a named element has its values reduced and its
# defaults supplied as `_rewrite_walk!` does. The DOCTYPE is read by the tokenizer. Any form this
# walk does not expect hands the document to `_rewrite_walk!`: `(false, nothing)`; otherwise
# `(true, bytes)`, `bytes` being `nothing` when nothing was rewritten.
function _rewrite_tags(s::AbstractString, attrs::Dict{String, Vector{_DeclaredAttr}})
    cu = codeunits(s)
    n = length(cu)
    out = nothing
    pos = 1
    written = Bool[]
    i = findnext(==(UInt8('<')), cu, _after_doctype(s))
    while i !== nothing && i < n
        b = cu[i + 1]
        if b == UInt8('/')                                   # an end tag: nothing in it counts
            i = findnext(==(UInt8('<')), cu, i + 2)
            continue
        elseif b == UInt8('?')                               # a processing instruction
            j = _find_bytes(cu, (UInt8('?'), UInt8('>')), i + 2)
            j == 0 && return (false, nothing)
            i = findnext(==(UInt8('<')), cu, j + 2)
            continue
        elseif b == UInt8('!')
            if i + 3 <= n && _spells(cu, i + 2, (UInt8('-'), UInt8('-')))
                j = _find_bytes(cu, (UInt8('-'), UInt8('-'), UInt8('>')), i + 4)
            elseif i + 8 <= n && _spells(cu, i + 2, _CDATA_OPENING)
                j = _find_bytes(cu, (UInt8(']'), UInt8(']'), UInt8('>')), i + 9)
            else
                return (false, nothing)
            end
            j == 0 && return (false, nothing)
            i = findnext(==(UInt8('<')), cu, j + 3)
            continue
        end
        _is_name_start_byte(b) || return (false, nothing)
        j = i + 1                                            # a start tag: its name
        while j <= n && XMLTokenizer.is_name_byte(cu[j])
            j += 1
        end
        current = get(attrs, SubString(s, i + 1, prevind(s, j)), nothing)
        if current !== nothing
            resize!(written, length(current))
            fill!(written, false)
        end
        k = j                                                # then its attributes, to its end
        while true
            while k <= n && XMLTokenizer.is_whitespace(cu[k])
                k += 1
            end
            k > n && return (false, nothing)
            c = cu[k]
            if c == UInt8('>') || (c == UInt8('/') && k < n && cu[k + 1] == UInt8('>'))
                if current !== nothing
                    for a in eachindex(current)
                        att = current[a]
                        (written[a] || att.supplied === nothing) && continue
                        out === nothing && (out = IOBuffer(sizehint = n))
                        Base.write(out, SubString(s, pos, prevind(s, k)))
                        Base.write(out, ' ', att.name, "=\"", att.supplied, '"')
                        pos = k
                    end
                end
                k += c == UInt8('>') ? 1 : 2
                break
            end
            XMLTokenizer.is_name_byte(c) || return (false, nothing)
            a0 = k
            while k <= n && XMLTokenizer.is_name_byte(cu[k])
                k += 1
            end
            a1 = k
            while k <= n && XMLTokenizer.is_whitespace(cu[k])
                k += 1
            end
            (k <= n && cu[k] == UInt8('=')) || return (false, nothing)
            k += 1
            while k <= n && XMLTokenizer.is_whitespace(cu[k])
                k += 1
            end
            (k <= n && (cu[k] == UInt8('"') || cu[k] == UInt8('\''))) || return (false, nothing)
            q = cu[k]
            v0 = k
            v1 = findnext(==(q), cu, k + 1)
            v1 === nothing && return (false, nothing)
            k = v1 + 1
            current === nothing && continue
            name = SubString(s, a0, prevind(s, a1))
            reduce_value = false
            for a in eachindex(current)
                current[a].name == name || continue
                written[a] = true
                reduce_value = current[a].normalize
            end
            reduce_value || continue
            inner = SubString(s, v0 + 1, prevind(s, v1))
            _changes_when_reduced(inner, nothing) || continue
            out === nothing && (out = IOBuffer(sizehint = n))
            Base.write(out, SubString(s, pos, v0))
            _write_reduced!(out, inner, nothing, q, 1)
            pos = v1
        end
        i = findnext(==(UInt8('<')), cu, k)
    end
    out === nothing && return (true, nothing)
    pos <= n && Base.write(out, SubString(s, pos))
    (true, take!(out))
end

# The position after the DOCTYPE, which the tokenizer reads over the prolog; 1 when the root
# element comes first.
function _after_doctype(s::AbstractString)
    for tok in XMLTokenizer.tokenize(s, 1)
        tok.kind === XMLTokenizer.TokenKinds.DOCTYPE_CLOSE &&
            return XMLTokenizer._data_stop(tok, s) + 1
        tok.kind === XMLTokenizer.TokenKinds.OPEN_TAG && return 1
    end
    1
end

const _CDATA_OPENING = Tuple(codeunits("[CDATA["))   # after the `<!`

# The index at or after `i` where the bytes `seq` start, or 0.
function _find_bytes(cu, seq::NTuple{N, UInt8}, i::Int) where {N}
    n = length(cu)
    while true
        j = findnext(==(seq[1]), cu, i)
        (j === nothing || j + N - 1 > n) && return 0
        _spells(cu, j, seq) && return j
        i = j + 1
    end
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

#-----------------------------------------------------------------------------# :strict (§2.8, §3.1, §4.1)
"""
    _strict_context(xml) -> _StrictContext

What `:strict` checks of the DTD before the parse, and what it hands the reference check. The
declarations are read, by the reader the inclusion uses, never searched as text.

A parameter-entity reference inside a markup declaration of the internal subset is refused
(§2.8, PEs in Internal Subset). A default value is refused when it holds a `<`, written or
through an entity (§3.1), or names an external or an unparsed entity (§3.1, §4.1), whether a
tag ever receives it or not.

The constraint "Entity Declared" (§4.1) binds only where a missing name is certain: in a
document without DTD, in one whose DTD is an internal subset with no parameter-entity reference
between its declarations, and in a standalone document, whatever its DTD holds. Where it binds,
a default value that names an entity not declared before it is refused as well. An entity
declared external or unparsed is declared: the reference check refuses an unparsed one anywhere
and an external one in an attribute value, and leaves an external one in content as written.
"""
function _strict_context(xml::AbstractString)
    _has_doctype(xml) || return _NO_DTD
    body = _doctype_body(xml)
    body === nothing && return _NO_DTD
    _check_pe_refs_in_markup(body)
    standalone = _declares_standalone(xml)
    rec = _StrictRecord()
    r = _subset_declarations(body, standalone, rec)
    names = standalone || (!_names_external_subset(body) && !rec.pe_refs)
    r === nothing || _check_defaults(rec, r.entities, names)
    _StrictContext(names, isempty(rec.external) ? nothing : rec.external,
                   isempty(rec.unparsed) ? nothing : rec.unparsed)
end

# A general entity's rank, and whether it is declared external or unparsed, the first
# declaration binding (§4.2). `s[start:stop - 1]` is the declaration: an external one that
# names a notation after its last literal is unparsed.
function _record_entity!(rec::_StrictRecord, decl, s::String, start::Int, stop::Int)
    haskey(rec.order, decl.name) && return
    rec.order[decl.name] = length(rec.order) + 1
    decl.value === nothing || return
    gt = prevind(s, stop)
    q = findprev(c -> c == '"' || c == '\'', s, gt)
    ndata = q !== nothing && q > start && occursin("NDATA", SubString(s, q, gt))
    push!(ndata ? rec.unparsed : rec.external, decl.name)
end

# Whether the DOCTYPE names an external subset: `SYSTEM` or `PUBLIC` after the root's name.
function _names_external_subset(body::AbstractString)
    s = String(body)
    name, pos = _dtd_name_at(s, _dtd_skip_ws(s, 1))
    name === nothing && return false
    rest = SubString(s, _dtd_skip_ws(s, pos))
    startswith(rest, "SYSTEM") || startswith(rest, "PUBLIC")
end

# WFC: PEs in Internal Subset (§2.8). Between two declarations a parameter-entity reference is
# allowed; inside one it is not: in the literal of an entity, nor anywhere in the body of an
# ELEMENT, ATTLIST or NOTATION outside a literal. A default value, a system or public literal, a
# comment and a processing instruction read `%` as a character.
function _check_pe_refs_in_markup(body::AbstractString)
    s = String(body)
    n = ncodeunits(s)
    pos = _subset_open(s)
    while pos <= n
        if s[pos] == ']'
            return
        elseif startswith(SubString(s, pos), "<!--")
            stop = findnext("-->", s, pos + 4)
            stop === nothing && return
            pos = last(stop) + 1
        elseif startswith(SubString(s, pos), "<?")
            stop = findnext("?>", s, pos + 2)
            stop === nothing && return
            pos = last(stop) + 1
        elseif startswith(SubString(s, pos), "<!")
            pos = _check_declaration(s, pos)
        else
            pos = nextind(s, pos)
        end
    end
end

# The position after the `[` that opens the internal subset, read past the literals of the
# DOCTYPE's head; past the end when it has none.
function _subset_open(s::String)
    n = ncodeunits(s)
    pos = 1
    while pos <= n
        c = s[pos]
        if c == '"' || c == '\''
            stop = findnext(c, s, nextind(s, pos))
            stop === nothing && return n + 1
            pos = nextind(s, stop)
        elseif c == '['
            return nextind(s, pos)
        else
            pos = nextind(s, pos)
        end
    end
    n + 1
end

# One declaration, from its `<!` to its `>`, checked for a parameter-entity reference. An
# entity's first literal is its value unless SYSTEM or PUBLIC comes before it, as a word after
# the declared name, which may itself be spelled SYSTEM; every other literal is an identifier
# or a default value. Returns the position after the `>`.
function _check_declaration(s::String, pos::Int)
    n = ncodeunits(s)
    entity = startswith(SubString(s, pos), "<!ENTITY")
    identifiers = false
    literals = 0
    words = 0                                        # ENTITY, then the name, then a keyword
    i = pos + 2
    while i <= n
        c = s[i]
        if c == '>'
            return i + 1
        elseif c == '"' || c == '\''
            stop = findnext(c, s, nextind(s, i))
            stop === nothing && return n + 1
            if entity && !identifiers && literals == 0
                k = nextind(s, i)
                while k < stop
                    if s[k] == '%'
                        j = _pe_ref_end(s, k, prevind(s, stop))
                        j > 0 && _pe_in_markup(SubString(s, k, j))
                    end
                    k = nextind(s, k)
                end
            end
            literals += 1
            i = nextind(s, stop)
        elseif c == '%'
            j = _pe_ref_end(s, i, n)
            j > 0 && _pe_in_markup(SubString(s, i, j))
            i = nextind(s, i)
        elseif _dtd_is_name_char(c)
            word, i = _dtd_name_at(s, i)
            words += 1
            words > 2 && (word == "SYSTEM" || word == "PUBLIC") && (identifiers = true)
        else
            i = nextind(s, i)
        end
    end
    n + 1
end

# The `;` that ends a parameter-entity reference opening at `s[i] == '%'`, no later than
# `stop`, or 0: a `%` followed by space is the mark of a parameter-entity declaration.
function _pe_ref_end(s::String, i::Int, stop::Int)
    j = nextind(s, i)
    (j <= stop && _dtd_is_name_char(s[j])) || return 0
    while j <= stop && _dtd_is_name_char(s[j])
        j = nextind(s, j)
    end
    j <= stop && s[j] == ';' ? j : 0
end

@noinline _pe_in_markup(ref::AbstractString) = error("not well-formed: parameter-entity ",
    "reference \"", ref, "\" inside a markup declaration of the internal subset (XML 1.0 §2.8)")

# The constraints on each default value (§3.1, §4.1), checked with the declarations, whether
# a tag receives the value or not. `rank` counts the general entities declared before the
# ATTLIST, among which an entity the value names must be where "Entity Declared" binds. An
# entity's text is checked through, as an attribute value that names it would include it.
function _check_defaults(rec::_StrictRecord, values::Dict{String, String}, names::Bool)
    for (element, attribute, literal, rank) in rec.defaults
        occursin('<', literal) && _bad_default(element, attribute, "holds a `<`", "§3.1")
        _check_default_refs(literal, rec, values, names, rank, element, attribute, 1)
    end
end

function _check_default_refs(text::AbstractString, rec::_StrictRecord, values::Dict{String, String},
                             names::Bool, rank::Int, element::String, attribute::String, depth::Int)
    depth > _MAX_ENTITY_DEPTH && return              # a cycle is refused before the parse
    cu = codeunits(text)
    n = length(cu)
    i = findnext(==(UInt8('&')), cu, 1)
    while i !== nothing
        next = i + 1
        if i + 1 <= n && cu[i + 1] == UInt8('#')
            j, _ = _charref_at(cu, i, n)
            j > 0 && (next = j + 1)
        elseif (j = _name_end(cu, i + 1, n)) > 0
            next = j + 1
            _, len = _predefined_at(cu, i, n)
            if len == 0
                name = SubString(text, i + 1, prevind(text, j))
                ref = String(cu[i:j])
                name in rec.unparsed &&
                    _bad_default(element, attribute, "names unparsed entity \"$ref\"", "§4.1")
                name in rec.external &&
                    _bad_default(element, attribute, "names external entity \"$ref\"", "§3.1")
                r = get(rec.order, name, 0)
                if names && r == 0
                    _bad_default(element, attribute, "names undeclared entity \"$ref\"", "§4.1")
                elseif names && depth == 1 && r > rank
                    _bad_default(element, attribute, "names entity \"$ref\", declared after it",
                                 "§4.1")
                end
                rep = get(values, name, nothing)
                if rep !== nothing
                    occursin('<', rep) &&
                        _bad_default(element, attribute, "holds a `<` through entity \"$ref\"",
                                     "§3.1")
                    _check_default_refs(rep, rec, values, names, rank, element, attribute,
                                        depth + 1)
                end
            end
        end
        i = findnext(==(UInt8('&')), cu, next)
    end
end

@noinline _bad_default(element, attribute, what, section) = error("not well-formed: the default ",
    "value of attribute \"", attribute, "\" of \"", element, "\" ", what, " (XML 1.0 ", section,
    ")")
