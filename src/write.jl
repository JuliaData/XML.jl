#-----------------------------------------------------------------------------# show (text/xml)

# Text and attribute values are escaped by `_write_escaped`, in escape.jl: the rules that
# `escape` applies.

# Cached indentation strings to avoid repeated allocation
const _MAX_CACHED_INDENT = 64
const _INDENT_STRINGS = [" " ^ n for n in 0:_MAX_CACHED_INDENT]
@inline function _indent_str(n::Int)
    0 <= n <= _MAX_CACHED_INDENT && return @inbounds _INDENT_STRINGS[n + 1]
    " " ^ n
end

# Serialize `key="escaped-value"` pairs for an attributes vector (no leading space outside).
# Uses byte-level `Base.write` instead of `print` to avoid the varargs-print dispatch
# overhead that shows up under profile when an element has many attributes.
function _print_attrs(io::IO, attributes)
    isnothing(attributes) && return
    for (k, v) in attributes
        Base.write(io, UInt8(' '))
        Base.write(io, k)
        Base.write(io, UInt8('='))
        Base.write(io, UInt8('"'))
        _write_escaped(io, v; attribute = true)
        Base.write(io, UInt8('"'))
    end
end

# XML white space (§2.3) is space, tab, CR and LF only: a text made of other spaces, such as
# U+00A0, is content. Read on the code units, since no byte of a character beyond ASCII is one
# of those four.
_is_xml_blank(s::AbstractString) = all(XMLTokenizer.is_whitespace, codeunits(s))

# Whitespace-only Text — emitted by the parser to round-trip source whitespace; pretty
# printing regenerates indentation from the tree shape and drops these.
@inline function _is_ignorable_text(node::Node)
    node.nodetype === Text && !isnothing(node.value) && _is_xml_blank(node.value)
end

# Mixed content = at least one Text/CData child carrying actual (non-whitespace) data.
# In that case the original whitespace is significant and we must not reformat.
function _has_significant_text(children)
    for c in children
        nt = c.nodetype
        if nt === Text
            (!isnothing(c.value) && !_is_xml_blank(c.value)) && return true
        elseif nt === CData
            return true
        end
    end
    false
end

# Main XML serializer. `depth` controls indentation; `preserve` propagates `xml:space=
# "preserve"` semantics down the subtree so we don't reformat whitespace-sensitive content.
# `pretty = false` comes with `preserve` for the whole tree: `xml:space` is not read, so that
# `xml:space="default"` cannot bring the layout back.
function _write_xml(io::IO, node::Node, depth::Int=0, indent::Int=2, preserve::Bool=false,
                    pretty::Bool=true)
    pad = preserve ? "" : _indent_str(indent * depth)
    nt = node.nodetype
    if nt === Text
        _write_escaped(io, node.value)
    elseif nt === Element
        # Check xml:space on this element
        child_preserve = preserve
        if pretty && !isnothing(node.attributes)
            for (k, v) in node.attributes
                k == "xml:space" && (child_preserve = v == "preserve")
            end
        end
        Base.write(io, pad)
        Base.write(io, UInt8('<'))
        Base.write(io, node.tag)
        _print_attrs(io, node.attributes)
        ch = node.children
        if isnothing(ch) || isempty(ch)
            Base.write(io, UInt8('/'))
            Base.write(io, UInt8('>'))
        elseif length(ch) == 1 && only(ch).nodetype === Text
            Base.write(io, UInt8('>'))
            _write_xml(io, only(ch), 0, 0, child_preserve, pretty)
            Base.write(io, UInt8('<'))
            Base.write(io, UInt8('/'))
            Base.write(io, node.tag)
            Base.write(io, UInt8('>'))
        else
            # If real Text or any CData lives among the children, treat as mixed
            # content and preserve the original layout. Otherwise pretty-print
            # and skip whitespace-only Text children — those were emitted by the
            # parser purely to round-trip source whitespace, and the writer
            # regenerates indentation from the tree shape.
            effective_preserve = child_preserve || _has_significant_text(ch)
            if effective_preserve
                Base.write(io, UInt8('>'))
            else
                Base.write(io, UInt8('>'))
                Base.write(io, UInt8('\n'))
            end
            for child in ch
                if !effective_preserve && _is_ignorable_text(child)
                    continue
                end
                _write_xml(io, child, depth + 1, indent, effective_preserve, pretty)
                effective_preserve || Base.write(io, UInt8('\n'))
            end
            effective_preserve || Base.write(io, pad)
            Base.write(io, UInt8('<'))
            Base.write(io, UInt8('/'))
            Base.write(io, node.tag)
            Base.write(io, UInt8('>'))
        end
    elseif nt === Declaration
        Base.write(io, pad)
        Base.write(io, "<?xml")
        _print_attrs(io, node.attributes)
        Base.write(io, "?>")
    elseif nt === ProcessingInstruction
        Base.write(io, pad)
        Base.write(io, "<?")
        Base.write(io, node.tag)
        if !isnothing(node.value)
            Base.write(io, UInt8(' '))
            Base.write(io, node.value)
        end
        Base.write(io, "?>")
    elseif nt === Comment
        Base.write(io, pad)
        Base.write(io, "<!--")
        Base.write(io, node.value)
        Base.write(io, "-->")
    elseif nt === CData
        Base.write(io, pad)
        Base.write(io, "<![CDATA[")
        Base.write(io, node.value)
        Base.write(io, "]]>")
    elseif nt === DTD
        Base.write(io, pad)
        Base.write(io, "<!DOCTYPE ")
        Base.write(io, node.value)
        Base.write(io, UInt8('>'))
    elseif nt === Document
        ch = node.children
        if !isnothing(ch)
            # Drop whitespace-only Text between top-level nodes when pretty
            # printing (XML grammar disallows text at document level, so any
            # such Text comes from inter-node whitespace in the source). Under
            # `preserve`, from `pretty = false`, the nodes are written as they
            # stand, with nothing between them.
            visible = preserve ? ch : filter(!_is_ignorable_text, ch)
            n_visible = length(visible)
            for (i, child) in enumerate(visible)
                _write_xml(io, child, 0, indent, preserve, pretty)
                !preserve && i < n_visible && Base.write(io, UInt8('\n'))
            end
        end
    end
end

Base.show(io::IO, ::MIME"text/xml", node::Node) = _write_xml(io, node)

#-----------------------------------------------------------------------------# write / read
"""
    write(node::Node; indentsize::Int=2, pretty::Bool=true) -> String
    write(io::IO, node::Node; kw...)
    write(filename::AbstractString, node::Node; kw...)

Write `node` as XML, with its text and attribute values escaped.

With `pretty = true`, the default, an element whose text children are all white space is laid
out again: these texts are dropped, and each child goes on its own line, indented by
`indentsize` spaces per level. The white space between the nodes of a document is dropped too,
and each node goes on its own line. An element that holds other text or a CDATA section, an
element whose only child is a text, and the content of `xml:space="preserve"` are written as
they stand.

With `pretty = false`, no white space is added or dropped between the nodes: a parsed document
keeps its whitespace text, and a tree built in code comes out with nothing between its nodes.
`indentsize` then has no effect.

Either way, the tags are written in one form, whatever the source had: one space before each
attribute, and `<x/>` for an element with no children, so `<br />` and `<br></br>` both come
out as `<br/>`.

```julia
julia> doc = parse("<p><b>bold</b> <i>italic</i></p>", Node);

julia> print(XML.write(doc))
<p>
  <b>bold</b>
  <i>italic</i>
</p>

julia> print(XML.write(doc; pretty = false))
<p><b>bold</b> <i>italic</i></p>
```
"""
write(node::Node; indentsize::Int=2, pretty::Bool=true) =
    (io = IOBuffer(); _write_xml(io, node, 0, indentsize, !pretty, pretty); String(take!(io)))
write(filename::AbstractString, node::Node; kw...) = open(io -> write(io, node; kw...), filename, "w")
write(io::IO, node::Node; indentsize::Int=2, pretty::Bool=true) =
    _write_xml(io, node, 0, indentsize, !pretty, pretty)
