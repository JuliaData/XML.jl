#-----------------------------------------------------------------------------# show (text/xml)

# Write XML-escaped content directly to IO (single pass, no intermediate string)
function _write_escaped(io::IO, s::String)
    start = 1
    i = 1
    n = ncodeunits(s)
    @inbounds while i <= n
        b = codeunit(s, i)
        esc = if b == UInt8('&'); "&amp;"
        elseif b == UInt8('<'); "&lt;"
        elseif b == UInt8('>'); "&gt;"
        elseif b == UInt8('"'); "&quot;"
        elseif b == UInt8('\''); "&apos;"
        else
            i += 1
            continue
        end
        i > start && GC.@preserve s Base.unsafe_write(io, pointer(s, start), (i - start) % UInt)
        print(io, esc)
        i += 1
        start = i
    end
    start <= n && GC.@preserve s Base.unsafe_write(io, pointer(s, start), (n - start + 1) % UInt)
    nothing
end

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
        _write_escaped(io, v)
        Base.write(io, UInt8('"'))
    end
end

# Whitespace-only Text — emitted by the parser to round-trip source whitespace; pretty
# printing regenerates indentation from the tree shape and drops these.
@inline function _is_ignorable_text(node::Node)
    node.nodetype === Text && !isnothing(node.value) && all(isspace, node.value)
end

# Mixed content = at least one Text/CData child carrying actual (non-whitespace) data.
# In that case the original whitespace is significant and we must not reformat.
function _has_significant_text(children)
    for c in children
        nt = c.nodetype
        if nt === Text
            (!isnothing(c.value) && !all(isspace, c.value)) && return true
        elseif nt === CData
            return true
        end
    end
    false
end

# Main XML serializer. `depth` controls indentation; `preserve` propagates `xml:space=
# "preserve"` semantics down the subtree so we don't reformat whitespace-sensitive content.
function _write_xml(io::IO, node::Node, depth::Int=0, indent::Int=2, preserve::Bool=false)
    pad = preserve ? "" : _indent_str(indent * depth)
    nt = node.nodetype
    if nt === Text
        _write_escaped(io, node.value)
    elseif nt === Element
        # Check xml:space on this element
        child_preserve = preserve
        if !isnothing(node.attributes)
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
            _write_xml(io, only(ch), 0, 0, child_preserve)
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
                _write_xml(io, child, depth + 1, indent, effective_preserve)
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
            # such Text comes from inter-node whitespace in the source).
            visible = preserve ? ch : filter(!_is_ignorable_text, ch)
            n_visible = length(visible)
            for (i, child) in enumerate(visible)
                _write_xml(io, child, 0, indent, preserve)
                i < n_visible && Base.write(io, UInt8('\n'))
            end
        end
    end
end

Base.show(io::IO, ::MIME"text/xml", node::Node) = _write_xml(io, node)

#-----------------------------------------------------------------------------# write / read
write(node::Node; indentsize::Int=2) = (io = IOBuffer(); _write_xml(io, node, 0, indentsize); String(take!(io)))
write(filename::AbstractString, node::Node; kw...) = open(io -> write(io, node; kw...), filename, "w")
write(io::IO, node::Node; indentsize::Int=2) = _write_xml(io, node, 0, indentsize)
