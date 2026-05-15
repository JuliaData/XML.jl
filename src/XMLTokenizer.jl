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
# `has_entities` records whether the raw bytes contain a `&`. It is set by the readers for
# `TEXT` and `ATTR_VALUE` (where entity references can appear) and stays `false` for every
# other token kind. The downstream parser uses it to skip `unescape`'s redundant byte scan
# when no entities are present.
#
# Field order matters: `has_entities` lives in the alignment padding that would otherwise
# sit between the 1-byte `kind` and the 24-byte `raw`. This keeps `sizeof(Token{String})`
# at 32 bytes instead of 40, which matters because tokens are allocated by the million
# during parse.
struct Token{S <: AbstractString}
    kind::TokenKinds.Kind
    has_entities::Bool
    raw::SubString{S}
end

# Backwards-compatible constructor for the many internal call sites that emit non-entity
# tokens (markup, names, close tokens, etc.).
@inline Token(kind::TokenKinds.Kind, raw::SubString{S}) where {S} = Token{S}(kind, false, raw)

function Base.show(io::IO, t::Token)
    print(io, t.kind, ": ", repr(String(t.raw)))
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
struct TokenizerState{S <: AbstractString}
    pos::Int
    mode::Mode
    pending::Token{S}  # buffered token for constructs that emit two tokens at once (e.g. content + close)
end

# Create an empty token (no pending token buffered)
@inline no_token(s::AbstractString) = Token(TokenKinds.TEXT, @inbounds SubString(s, 1, 0))
# Check whether the state has a buffered pending token
@inline has_pending(st::TokenizerState) = !isempty(st.pending.raw)


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
    state::TokenizerState{S}
    done::Bool
end

StatefulTokenizer(t::Tokenizer{S}) where {S <: AbstractString} =
    StatefulTokenizer{S}(t, TokenizerState(t.start, M_DEFAULT, no_token(t.data)), false)

Base.IteratorSize(::Type{<:StatefulTokenizer}) = Base.SizeUnknown()
Base.eltype(::Type{StatefulTokenizer{S}}) where {S} = Token{S}

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
Base.eltype(::Type{Tokenizer{S}}) where {S} = Token{S}

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

# Lookup table for XML name bytes (letter, digit, _, -, ., :)
const NAME_BYTE_TABLE = let t = falses(256)
    for r in (UInt8('a'):UInt8('z'), UInt8('A'):UInt8('Z'), UInt8('0'):UInt8('9'))
        for b in r; t[b + 1] = true; end
    end
    for b in (UInt8('_'), UInt8('-'), UInt8('.'), UInt8(':')); t[b + 1] = true; end
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
    raw = @inbounds SubString(data, start, prevind(data, end_pos))
    has_amp = occursin('&', raw)
    tok = Token{typeof(data)}(TokenKinds.TEXT, has_amp, raw)
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
        tok = Token(TokenKinds.PI_OPEN, @inbounds SubString(data, start, pos - 1))
        (tok, TokenizerState(pos, M_PI, no_token(data)))
    end
end

#-----------------------------------------------------------------------# Tags
# Read '<name' and enter tag-attribute mode
function read_open_tag_start(data::AbstractString, pos::Int, start::Int)
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    tok = Token(TokenKinds.OPEN_TAG, @inbounds SubString(data, start, pos - 1))
    (tok, TokenizerState(pos, M_TAG, no_token(data)))
end

# Read '</name' and enter close-tag mode
function read_close_tag_start(data::AbstractString, pos::Int, start::Int)
    @inbounds while !iseof(data, pos) && is_name_byte(peek(data, pos))
        pos += 1
    end
    tok = Token(TokenKinds.CLOSE_TAG, @inbounds SubString(data, start, pos - 1))
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
    name_end = pos - 1
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
    raw = @inbounds SubString(data, start, pos - 1)
    tok = Token{typeof(data)}(TokenKinds.ATTR_VALUE, has_amp, raw)
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

#-----------------------------------------------------------------------# Utility functions

"""
    tag_name(token::Token) -> SubString{String}

Extract the element name from an `OPEN_TAG` or `CLOSE_TAG` token.
"""
function tag_name(token::Token)
    if token.kind == TokenKinds.OPEN_TAG
        @inbounds SubString(token.raw, 2, ncodeunits(token.raw))  # skip '<'
    elseif token.kind == TokenKinds.CLOSE_TAG
        @inbounds SubString(token.raw, 3, ncodeunits(token.raw))  # skip '</'
    else
        throw(ArgumentError("tag_name requires OPEN_TAG or CLOSE_TAG, got $(token.kind)"))
    end
end

"""
    attr_value(token::Token) -> SubString{String}

Strip the surrounding quotes from an `ATTR_VALUE` token.
"""
function attr_value(token::Token)
    token.kind == TokenKinds.ATTR_VALUE ||
        throw(ArgumentError("attr_value requires ATTR_VALUE, got $(token.kind)"))
    @inbounds SubString(token.raw, 2, prevind(token.raw, lastindex(token.raw)))
end

"""
    pi_target(token::Token) -> SubString{String}

Extract the target name from a `PI_OPEN` or `XML_DECL_OPEN` token.
"""
function pi_target(token::Token)
    (token.kind == TokenKinds.PI_OPEN || token.kind == TokenKinds.XML_DECL_OPEN) ||
        throw(ArgumentError("pi_target requires PI_OPEN or XML_DECL_OPEN, got $(token.kind)"))
    @inbounds SubString(token.raw, 3, ncodeunits(token.raw))  # skip '<?'
end

end # module XMLTokenizer
