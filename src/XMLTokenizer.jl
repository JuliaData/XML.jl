module XMLTokenizer

#-----------------------------------------------------------------------# TokenKinds
baremodule TokenKinds
    import Base: @enum

    @enum Kind::UInt8 begin
        # Character data
        TEXT               # text content between markup

        # Element tags
        OPEN_TAG           # <name
        CLOSE_TAG          # </name
        TAG_CLOSE          # >
        SELF_CLOSE         # />
        ATTR_NAME          # attribute name
        ATTR_VALUE         # "value" or 'value' (with quotes in raw)

        # CDATA sections
        CDATA_OPEN         # <![CDATA[
        CDATA_CONTENT      # raw text content
        CDATA_CLOSE        # ]]>

        # Comments
        COMMENT_OPEN       # <!--
        COMMENT_CONTENT    # comment text
        COMMENT_CLOSE      # -->

        # Processing instructions
        PI_OPEN            # <?target (includes target name)
        PI_CONTENT         # PI body text
        PI_CLOSE           # ?>

        # XML declaration (<?xml ...?>)
        XML_DECL_OPEN      # <?xml
        XML_DECL_CLOSE     # ?>
        # (reuses ATTR_NAME / ATTR_VALUE for pseudo-attributes)

        # DOCTYPE
        DOCTYPE_OPEN       # <!DOCTYPE (or other <! declarations)
        DOCTYPE_CONTENT    # declaration body
        DOCTYPE_CLOSE      # >
    end
end

#-----------------------------------------------------------------------# Token
# A token is a (kind, has_entities, byte-range) triple. It stores only the *range* into
# the source — `offset` (0-based byte offset) and `ncodeunits` (byte length), mirroring
# the internal fields of the `SubString` it used to hold. Dropping the SubString's string
# reference makes `Token` an ISBITS type, so the `(Token, TokenizerState)` tuple returned
# by `iterate` no longer heap-allocates per token (previously the dominant parse cost).
# Recover the text with `raw(token, data)`, passing the original source string.
#
# `has_entities` records whether the raw bytes contain a `&`. It is set by the readers for
# `TEXT` and `ATTR_VALUE` (where entity references can appear) and stays `false` for every
# other token kind, letting the downstream parser skip `unescape`'s redundant byte scan
# when no entities are present.
struct Token
    kind::TokenKinds.Kind
    has_entities::Bool
    offset::Int        # == SubString.offset (0-based byte offset into the source)
    ncodeunits::Int    # == SubString.ncodeunits (byte length of the token text)
end

# Emit-site constructors: take the throwaway `SubString` view a reader just built and keep
# only its byte range. The SubString does not escape, so this allocates nothing. They keep
# every `Token(KIND, SubString(data, a, b))` / `Token(KIND, has_amp, view)` site unchanged.
@inline Token(kind::TokenKinds.Kind, raw::SubString) = Token(kind, false, raw.offset, raw.ncodeunits)
@inline Token(kind::TokenKinds.Kind, has_entities::Bool, raw::SubString) =
    Token(kind, has_entities, raw.offset, raw.ncodeunits)

# Recover the token's text as a zero-copy `SubString` of its source `data`. `prevind` lands
# the end index on the START of the last character, so the round-trip is correct for
# multibyte UTF-8 — a naive `SubString(data, off+1, off+ncu)` would pass a continuation byte
# as the end index and throw. `_token_root` resolves `data::SubString` to its parent string
# (token offsets are root-relative, since `SubString(::SubString, …)` flattens to the root).
@inline _token_root(s::AbstractString) = s
@inline _token_root(s::SubString)      = s.string
@inline function raw(t::Token, data::AbstractString)
    r = _token_root(data)
    @inbounds SubString(r, t.offset + 1, prevind(r, t.offset + t.ncodeunits + 1))
end

function Base.show(io::IO, t::Token)
    print(io, t.kind, " @", t.offset, "+", t.ncodeunits)
end

#-----------------------------------------------------------------------# Tokenizer mode
@enum Mode::UInt8 begin
    M_DEFAULT            # normal content mode
    M_TAG                # inside open tag, reading attributes
    M_TAG_VALUE          # expecting quoted attribute value
    M_CLOSE_TAG          # inside close tag, expecting >
    M_XML_DECL           # inside <?xml, reading pseudo-attributes
    M_XML_DECL_VALUE     # expecting quoted attr value in xml decl
    M_COMMENT            # after <!--, reading content
    M_CDATA              # after <![CDATA[, reading content
    M_PI                 # after <?target, reading content
    M_DOCTYPE            # after <!DOCTYPE, reading content
end

#-----------------------------------------------------------------------# TokenizerState (immutable, SROA-friendly)
struct TokenizerState
    pos::Int
    mode::Mode
    pending::Token  # buffered token for constructs that emit two tokens at once (e.g. content + close)
end

# Create an empty token (no pending token buffered). The throwaway `SubString(s,1,0)` has
# offset/ncodeunits 0, so the resulting Token is the (kind, false, 0, 0) sentinel.
@inline no_token(s::AbstractString) = Token(TokenKinds.TEXT, @inbounds SubString(s, 1, 0))
# Check whether the state has a buffered pending token (the sentinel has ncodeunits 0;
# every real pending token — COMMENT/CDATA/PI/DOCTYPE close — is non-empty).
@inline has_pending(st::TokenizerState) = st.pending.ncodeunits != 0


#-----------------------------------------------------------------------# Tokenizer (immutable iterator)
"""
    tokenize(xml::AbstractString) -> Tokenizer

Return a lazy iterator of `Token`s over the XML string `xml`.
"""
struct Tokenizer{S <: AbstractString}
    data::S
    start::Int
end

tokenize(xml::AbstractString) = Tokenizer(xml, 1)
tokenize(xml::AbstractString, pos::Int) = StatefulTokenizer(Tokenizer(xml, pos))

# Lightweight mutable holder that drives the immutable `Tokenizer`'s iterate protocol with
# a single state field — avoids the `Union{VS,Nothing}` field and per-iteration tuple
# storage that `Iterators.Stateful` carries.
mutable struct StatefulTokenizer{S <: AbstractString}
    const t::Tokenizer{S}
    state::TokenizerState
    done::Bool
end

StatefulTokenizer(t::Tokenizer{S}) where {S <: AbstractString} =
    StatefulTokenizer{S}(t, TokenizerState(t.start, M_DEFAULT, no_token(t.data)), false)

Base.IteratorSize(::Type{<:StatefulTokenizer}) = Base.SizeUnknown()
Base.eltype(::Type{<:StatefulTokenizer}) = Token

@inline function Base.iterate(st::StatefulTokenizer, _ = nothing)
    st.done && return nothing
    r = iterate(st.t, st.state)
    if r === nothing
        st.done = true
        return nothing
    end
    st.state = r[2]
    (r[1], nothing)
end

function Base.show(io::IO, t::Tokenizer)
    n = ncodeunits(t.data)
    print(io, "Tokenizer(")
    t.start > 1 && print(io, t.start, "/")
    print(io, Base.format_bytes(n), ")")
end

Base.IteratorSize(::Type{<:Tokenizer}) = Base.SizeUnknown()
Base.eltype(::Type{<:Tokenizer}) = Token

function Base.iterate(t::Tokenizer, st::TokenizerState=TokenizerState(t.start, M_DEFAULT, no_token(t.data)))
    (; data) = t
    (; pending, pos, mode) = st

    if has_pending(st)
        return (pending, TokenizerState(pos, mode, no_token(data)))
    end
    iseof(data, pos) && return nothing

    if mode == M_DEFAULT
        peek(data, pos) == UInt8('<') ? read_markup(data, pos) : read_text(data, pos)
    elseif mode == M_TAG || mode == M_XML_DECL
        read_in_tag(data, pos, mode)
    elseif mode == M_TAG_VALUE || mode == M_XML_DECL_VALUE
        read_attr_value(data, pos, mode)
    elseif mode == M_CLOSE_TAG
        read_close_tag_end(data, pos)
    elseif mode == M_COMMENT
        read_comment_body(data, pos)
    elseif mode == M_CDATA
        read_cdata_body(data, pos)
    elseif mode == M_PI
        read_pi_body(data, pos)
    else  # M_DOCTYPE
        read_doctype_body(data, pos)
    end
end

#-----------------------------------------------------------------------# Internal helpers
# Check if pos is past the end of data
@inline iseof(data::AbstractString, pos::Int)::Bool = pos > ncodeunits(data)
# Read the byte at pos without bounds checking
@inline peek(data::AbstractString, pos::Int)::UInt8 = @inbounds codeunit(data, pos)
# Check if pos + offset is within bounds
@inline canpeek(data::AbstractString, pos::Int, offset::Int)::Bool = pos + offset <= ncodeunits(data)

# Lookup table for XML name bytes (letter, digit, _, -, ., :), plus every non-ASCII
# byte (0x80–0xFF) — the UTF-8 lead/continuation bytes — so Unicode names like `<café>`
# tokenize. Lenient per-byte rule: exact XML NameStartChar/NameChar ranges aren't validated.
const NAME_BYTE_TABLE = let t = falses(256)
    for r in (UInt8('a'):UInt8('z'), UInt8('A'):UInt8('Z'), UInt8('0'):UInt8('9'))
        for b in r; t[b + 1] = true; end
    end
    for b in (UInt8('_'), UInt8('-'), UInt8('.'), UInt8(':')); t[b + 1] = true; end
    for b in 0x80:0xFF; t[b + 1] = true; end
    NTuple{256,Bool}(t)
end
@inline is_name_byte(b::UInt8)::Bool = @inbounds NAME_BYTE_TABLE[b + 1]

# Check if byte is XML whitespace (space, tab, newline, carriage return)
@inline function is_whitespace(b::UInt8)::Bool
    b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')
end

# Advance pos past any whitespace bytes
@inline function skip_whitespace(data::AbstractString, pos::Int)::Int
    @inbounds while !iseof(data, pos) && is_whitespace(peek(data, pos))
        pos += 1
    end
    pos
end

# Advance pos past a quoted string (single or double quotes)
function skip_quoted(data::AbstractString, pos::Int)::Int
    q = @inbounds peek(data, pos)
    pos += 1
    @inbounds while !iseof(data, pos)
        peek(data, pos) == q && return pos + 1
        pos += 1
    end
    error("Unterminated quoted string")
end

# Throw a tokenizer error with position context (noinline to keep error paths out of hot code)
@noinline err(msg::AbstractString, pos::Int) = throw(ArgumentError("XML tokenizer error at position $pos: $msg"))

#-----------------------------------------------------------------------# Text and markup
# Read text content up to the next '<'. Uses `findnext` (memchr-backed for `String`) to
# find the end-of-text delimiter, then scans for `&` only within the text region — a full
# document `findnext('&', ...)` would be O(doc_size) per text token and degrade to
# O(doc_size²) on entity-free documents.
function read_text(data::AbstractString, pos::Int)
    start = pos
    n = ncodeunits(data)
    lt_idx = findnext('<', data, pos)
    end_pos = isnothing(lt_idx) ? n + 1 : lt_idx
    text = @inbounds SubString(data, start, prevind(data, end_pos))
    has_amp = occursin('&', text)
    tok = Token(TokenKinds.TEXT, has_amp, text)
    (tok, TokenizerState(end_pos, M_DEFAULT, no_token(data)))
end

# Dispatch on the character after '<' to the appropriate reader
function read_markup(data::AbstractString, pos::Int)
    start = pos
    pos += 1  # skip '<'
    iseof(data, pos) && err("unexpected end of input after '<'", start)

    b = peek(data, pos)
    if b == UInt8('!')
        read_bang(data, pos + 1, start)
    elseif b == UInt8('?')
        read_pi_start(data, pos + 1, start)
    elseif b == UInt8('/')
        read_close_tag_start(data, pos + 1, start)
    else
        read_open_tag_start(data, pos, start)
    end
end

#-----------------------------------------------------------------------# <! dispatch
# Handle '<!' — comment, CDATA, or DOCTYPE
function read_bang(data::AbstractString, pos::Int, start::Int)
    # Comment: <!--
    if !iseof(data, pos) && peek(data, pos) == UInt8('-')
        pos += 1
        (!iseof(data, pos) && peek(data, pos) == UInt8('-')) || err("expected '<!--'", start)
        pos += 1
        tok = Token(TokenKinds.COMMENT_OPEN, @inbounds SubString(data, start, pos - 1))
        return (tok, TokenizerState(pos, M_COMMENT, no_token(data)))
    end

    # CDATA: <![CDATA[
    if !iseof(data, pos) && peek(data, pos) == UInt8('[')
        pos += 1
        for expected in (UInt8('C'), UInt8('D'), UInt8('A'), UInt8('T'), UInt8('A'), UInt8('['))
            iseof(data, pos) && err("unterminated CDATA", start)
            peek(data, pos) == expected || err("invalid CDATA section", start)
            pos += 1
        end
        tok = Token(TokenKinds.CDATA_OPEN, @inbounds SubString(data, start, pos - 1))
        return (tok, TokenizerState(pos, M_CDATA, no_token(data)))
    end

    # <!DOCTYPE ...> or other <! declaration
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    tok = Token(TokenKinds.DOCTYPE_OPEN, @inbounds SubString(data, start, pos - 1))
    (tok, TokenizerState(pos, M_DOCTYPE, no_token(data)))
end

#-----------------------------------------------------------------------# <? (PI / XML declaration)
# Handle '<?' — XML declaration or processing instruction
function read_pi_start(data::AbstractString, pos::Int, start::Int)
    name_start = pos
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end

    is_xml = (pos - name_start == 3) &&
        codeunit(data, name_start)     == UInt8('x') &&
        codeunit(data, name_start + 1) == UInt8('m') &&
        codeunit(data, name_start + 2) == UInt8('l')

    if is_xml
        tok = Token(TokenKinds.XML_DECL_OPEN, @inbounds SubString(data, start, pos - 1))
        (tok, TokenizerState(pos, M_XML_DECL, no_token(data)))
    else
        tok = Token(TokenKinds.PI_OPEN, @inbounds SubString(data, start, prevind(data, pos)))
        (tok, TokenizerState(pos, M_PI, no_token(data)))
    end
end

#-----------------------------------------------------------------------# Tags
# Read '<name' and enter tag-attribute mode
function read_open_tag_start(data::AbstractString, pos::Int, start::Int)
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    tok = Token(TokenKinds.OPEN_TAG, @inbounds SubString(data, start, prevind(data, pos)))
    (tok, TokenizerState(pos, M_TAG, no_token(data)))
end

# Read '</name' and enter close-tag mode
function read_close_tag_start(data::AbstractString, pos::Int, start::Int)
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    tok = Token(TokenKinds.CLOSE_TAG, @inbounds SubString(data, start, prevind(data, pos)))
    (tok, TokenizerState(pos, M_CLOSE_TAG, no_token(data)))
end

# Consume the '>' that closes a '</name>' tag
function read_close_tag_end(data::AbstractString, pos::Int)
    pos = skip_whitespace(data, pos)
    iseof(data, pos) && err("unterminated close tag", pos)
    peek(data, pos) == UInt8('>') || err("expected '>'", pos)
    tok = Token(TokenKinds.TAG_CLOSE, @inbounds SubString(data, pos, pos))
    (tok, TokenizerState(pos + 1, M_DEFAULT, no_token(data)))
end

#-----------------------------------------------------------------------# Attributes (shared by M_TAG and M_XML_DECL)
# Read the next attribute name or tag-close delimiter (>, />, ?>)
function read_in_tag(data::AbstractString, pos::Int, mode::Mode)
    pos = skip_whitespace(data, pos)
    iseof(data, pos) && err("unterminated tag", pos)

    b = peek(data, pos)
    is_decl = (mode == M_XML_DECL)

    # Check for end delimiters
    if is_decl
        if b == UInt8('?') && canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('>')
            tok = Token(TokenKinds.XML_DECL_CLOSE, @inbounds SubString(data, pos, pos + 1))
            return (tok, TokenizerState(pos + 2, M_DEFAULT, no_token(data)))
        end
    else
        if b == UInt8('>')
            tok = Token(TokenKinds.TAG_CLOSE, @inbounds SubString(data, pos, pos))
            return (tok, TokenizerState(pos + 1, M_DEFAULT, no_token(data)))
        end
        if b == UInt8('/') && canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('>')
            tok = Token(TokenKinds.SELF_CLOSE, @inbounds SubString(data, pos, pos + 1))
            return (tok, TokenizerState(pos + 2, M_DEFAULT, no_token(data)))
        end
    end

    # Attribute name
    name_start = pos
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    name_end = prevind(data, pos)
    name_start > name_end && err("expected attribute name or tag close", pos)

    # Consume '=' and surrounding whitespace (not part of any token)
    pos = skip_whitespace(data, pos)
    (!iseof(data, pos) && peek(data, pos) == UInt8('=')) || err("expected '=' after attribute name", pos)
    pos += 1
    pos = skip_whitespace(data, pos)

    next_state = is_decl ? M_XML_DECL_VALUE : M_TAG_VALUE
    tok = Token(TokenKinds.ATTR_NAME, @inbounds SubString(data, name_start, name_end))
    (tok, TokenizerState(pos, next_state, no_token(data)))
end

# Read a quoted attribute value (including the quotes). Same shape as `read_text`: use
# `findnext` for the closing quote (memchr-backed for `String`), then a bounded `occursin`
# over the value range for entity detection so we never scan past the quote.
function read_attr_value(data::AbstractString, pos::Int, mode::Mode)
    iseof(data, pos) && err("expected attribute value", pos)

    q = peek(data, pos)
    (q == UInt8('"') || q == UInt8('\'')) || err("expected quoted attribute value", pos)

    start = pos
    pos += 1  # skip opening quote
    quote_char = Char(q)
    close_idx = findnext(quote_char, data, pos)
    isnothing(close_idx) && err("unterminated attribute value", start)
    # Value range is [pos, close_idx - 1]; entity check is bounded to this view.
    inner = @inbounds SubString(data, pos, prevind(data, close_idx))
    has_amp = occursin('&', inner)
    pos = close_idx + 1  # one past the closing quote (always ASCII)

    next_state = (mode == M_XML_DECL_VALUE) ? M_XML_DECL : M_TAG
    valraw = @inbounds SubString(data, start, pos - 1)
    tok = Token(TokenKinds.ATTR_VALUE, has_amp, valraw)
    (tok, TokenizerState(pos, next_state, no_token(data)))
end

#-----------------------------------------------------------------------# Content bodies (comment, CDATA, PI, DOCTYPE)
# Scan for '-->' and emit comment content + close tokens
function read_comment_body(data::AbstractString, pos::Int)
    start = pos
    @inbounds while !iseof(data, pos)
        if peek(data, pos) == UInt8('-') &&
           canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('-') &&
           canpeek(data, pos, 2) && peek(data, pos + 2) == UInt8('>')
            content_end = prevind(data, pos)
            close_start = pos
            pos += 3
            pending = Token(TokenKinds.COMMENT_CLOSE, SubString(data, close_start, pos - 1))
            tok = Token(TokenKinds.COMMENT_CONTENT, SubString(data, start, content_end))
            return (tok, TokenizerState(pos, M_DEFAULT, pending))
        end
        pos += 1
    end
    err("unterminated comment", start)
end

# Scan for ']]>' and emit CDATA content + close tokens
function read_cdata_body(data::AbstractString, pos::Int)
    start = pos
    @inbounds while !iseof(data, pos)
        if peek(data, pos) == UInt8(']') &&
           canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8(']') &&
           canpeek(data, pos, 2) && peek(data, pos + 2) == UInt8('>')
            content_end = prevind(data, pos)
            close_start = pos
            pos += 3
            pending = Token(TokenKinds.CDATA_CLOSE, SubString(data, close_start, pos - 1))
            tok = Token(TokenKinds.CDATA_CONTENT, SubString(data, start, content_end))
            return (tok, TokenizerState(pos, M_DEFAULT, pending))
        end
        pos += 1
    end
    err("unterminated CDATA section", start)
end

# Scan for '?>' and emit PI content + close tokens
function read_pi_body(data::AbstractString, pos::Int)
    start = pos
    @inbounds while !iseof(data, pos)
        if peek(data, pos) == UInt8('?') && canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('>')
            content_end = prevind(data, pos)
            close_start = pos
            pos += 2
            pending = Token(TokenKinds.PI_CLOSE, SubString(data, close_start, pos - 1))
            tok = Token(TokenKinds.PI_CONTENT, SubString(data, start, content_end))
            return (tok, TokenizerState(pos, M_DEFAULT, pending))
        end
        pos += 1
    end
    err("unterminated processing instruction", start)
end

# Scan DOCTYPE body, handling nested brackets, quotes, and comments
function read_doctype_body(data::AbstractString, pos::Int)
    start = pos
    depth = 0
    @inbounds while !iseof(data, pos)
        b = peek(data, pos)
        if b == UInt8('-') && canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('-') &&
                pos >= 3 &&
                codeunit(data, pos - 1) == UInt8('!') &&
                codeunit(data, pos - 2) == UInt8('<')
            # Inside a <!-- comment: skip until -->
            pos += 2  # skip "--"
            while !iseof(data, pos)
                if peek(data, pos) == UInt8('-') && canpeek(data, pos, 1) && peek(data, pos + 1) == UInt8('-') &&
                        canpeek(data, pos, 2) && peek(data, pos + 2) == UInt8('>')
                    pos += 3  # skip "-->"
                    break
                end
                pos += 1
            end
        elseif b == UInt8('"') || b == UInt8('\'')
            pos = skip_quoted(data, pos)
        elseif b == UInt8('[')
            depth += 1
            pos += 1
        elseif b == UInt8(']')
            depth -= 1
            pos += 1
        elseif b == UInt8('>') && depth == 0
            content_end = prevind(data, pos)
            close_start = pos
            pos += 1
            pending = Token(TokenKinds.DOCTYPE_CLOSE, @inbounds SubString(data, close_start, pos - 1))
            tok = Token(TokenKinds.DOCTYPE_CONTENT, @inbounds SubString(data, start, content_end))
            return (tok, TokenizerState(pos, M_DEFAULT, pending))
        else
            pos += 1
        end
    end
    err("unterminated DOCTYPE", start)
end

#-----------------------------------------------------------------------# skip_element (byte-level subtree skip)
# Advance past an entire element subtree WITHOUT emitting its internal tokens — a byte
# scan that counts element-nesting depth and respects CDATA / comment / PI / quoted-`>`
# boundaries. O(subtree bytes) but with a far tighter loop than full tokenization (no
# token emission, no SubString construction). Used by `skip_element!` for structural
# walks (e.g. layer discovery) that classify a node but don't need its contents.

# Find the `>` ending the tag whose `<` is at index `i`, skipping quoted attribute
# values (where `>` may appear literally). Returns the index of that `>` (or `n`).
@inline function _scan_tag_end(data::AbstractString, i::Int, n::Int)
    j = i + 1
    @inbounds while j <= n
        b = codeunit(data, j)
        if b == UInt8('"') || b == UInt8('\'')
            j += 1
            while j <= n && codeunit(data, j) != b
                j += 1
            end
        elseif b == UInt8('>')
            return j
        end
        j += 1
    end
    return n
end

# `openpos`: 1-based index of the `<` starting the element to skip. Returns the 1-based
# index just past its matching close (`</name>` or `/>`), or `ncodeunits(data)+1` if the
# document ends first (lenient, mirroring the tokenizer's EOF handling).
function _skip_element_raw(data::AbstractString, openpos::Int)
    n = ncodeunits(data)
    depth = 0
    i = openpos
    @inbounds while i <= n
        lt = findnext('<', data, i)
        lt === nothing && return n + 1
        i = lt
        nxt = (i + 1 <= n) ? codeunit(data, i + 1) : 0x00
        if nxt == UInt8('!')
            nx2 = (i + 2 <= n) ? codeunit(data, i + 2) : 0x00
            if nx2 == UInt8('-')            # <!-- comment -->
                cl = findnext("-->", data, i)
                cl === nothing && return n + 1
                i = last(cl) + 1
            elseif nx2 == UInt8('[')        # <![CDATA[ ... ]]>
                cl = findnext("]]>", data, i)
                cl === nothing && return n + 1
                i = last(cl) + 1
            else                            # <!DOCTYPE ...> / other <! declaration
                i = _scan_tag_end(data, i, n) + 1
            end
        elseif nxt == UInt8('?')            # <? ... ?>
            cl = findnext("?>", data, i)
            cl === nothing && return n + 1
            i = last(cl) + 1
        elseif nxt == UInt8('/')            # </name> close
            e = _scan_tag_end(data, i, n)
            depth -= 1
            i = e + 1
            depth == 0 && return i
        else                                # <name ...> open or <name .../> self-close
            e = _scan_tag_end(data, i, n)
            self_closed = e > 1 && codeunit(data, e - 1) == UInt8('/')
            i = e + 1
            self_closed || (depth += 1)
            depth == 0 && return i
        end
    end
    return n + 1
end

#-----------------------------------------------------------------------# Utility functions

"""
    tag_name(token::Token, data) -> SubString

Extract the element name from an `OPEN_TAG` or `CLOSE_TAG` token. `data` is the source the
token was scanned from (needed to recover the text — see [`raw`](@ref)).
"""
function tag_name(token::Token, data)
    r = raw(token, data)
    if token.kind == TokenKinds.OPEN_TAG
        @inbounds SubString(r, 2, lastindex(r))  # skip '<'; lastindex (not ncodeunits) for multibyte names
    elseif token.kind == TokenKinds.CLOSE_TAG
        @inbounds SubString(r, 3, lastindex(r))  # skip '</'
    else
        throw(ArgumentError("tag_name requires OPEN_TAG or CLOSE_TAG, got $(token.kind)"))
    end
end

"""
    attr_value(token::Token, data) -> SubString

Strip the surrounding quotes from an `ATTR_VALUE` token. `data` is the source string.
"""
function attr_value(token::Token, data)
    token.kind == TokenKinds.ATTR_VALUE ||
        throw(ArgumentError("attr_value requires ATTR_VALUE, got $(token.kind)"))
    r = raw(token, data)
    @inbounds SubString(r, 2, prevind(r, lastindex(r)))
end

"""
    pi_target(token::Token, data) -> SubString

Extract the target name from a `PI_OPEN` or `XML_DECL_OPEN` token. `data` is the source string.
"""
function pi_target(token::Token, data)
    (token.kind == TokenKinds.PI_OPEN || token.kind == TokenKinds.XML_DECL_OPEN) ||
        throw(ArgumentError("pi_target requires PI_OPEN or XML_DECL_OPEN, got $(token.kind)"))
    r = raw(token, data)
    @inbounds SubString(r, 3, lastindex(r))  # skip '<?'
end

end # module XMLTokenizer
