# The cost of reading one worksheet cell with a `Cursor`, reading by reading: `next!` alone,
# two readings made of the calls of v0.4.10, one made of the calls on trial (`XML.is_tag`,
# `XML.attribute!`, `XML.simple_value!`), and a byte scan written for this one shape, which
# checks nothing and decodes nothing. The sheet is made here: 100,000 cells of the shape
# `<c r="A1" s="3"><v>42.5</v></c>`, 20 to a row.
#
# Run it in one fresh process per version of XML.jl, from an environment that holds XML.jl
# and BenchmarkTools. On a version without the calls on trial, their reading is left out.
#
#     julia --project=benchmarks benchmarks/cursor_cells.jl
using XML, BenchmarkTools
using XML: Cursor, next!, nodetype, tag, eachattribute!, is_simple_value, skip_element!

cell(r, k) = "<c r=\"$(Char('A' + (k - 1) % 26))$r\" s=\"3\"><v>42.5</v></c>"
row(r) = "<row r=\"$r\">" * join(cell(r, k) for k in 1:20) * "</row>"
const SHEET = "<sheetData>" * join(row(r) for r in 1:5000) * "</sheetData>"
const NCELLS = 100_000

# `next!` to the end, nothing read.
function walk_next(s)
    c = Cursor(s)
    n = 0
    while next!(c) !== nothing
        n += 1
    end
    return n
end

# `r` and `s` by `eachattribute!`, the text of `<v>` by `is_simple_value`; `skip_element!`.
function walk_each(s)
    c = Cursor(s)
    acc = 0
    while next!(c) !== nothing
        nodetype(c) === XML.Element || continue
        t = tag(c)
        if t == "c"
            for (k, v) in eachattribute!(c)
                (k == "r" || k == "s") && (acc += ncodeunits(v))
            end
        elseif t == "v"
            v = is_simple_value(c)
            v === nothing || (acc += ncodeunits(v))
            skip_element!(c)
        end
    end
    return acc
end

# The same, `r` and `s` by two `get`.
function walk_get(s)
    c = Cursor(s)
    acc = 0
    while next!(c) !== nothing
        nodetype(c) === XML.Element || continue
        t = tag(c)
        if t == "c"
            r = get(c, "r", nothing)
            r === nothing || (acc += ncodeunits(r))
            st = get(c, "s", nothing)
            st === nothing || (acc += ncodeunits(st))
        elseif t == "v"
            v = is_simple_value(c)
            v === nothing || (acc += ncodeunits(v))
            skip_element!(c)
        end
    end
    return acc
end

# The calls on trial: the name by `is_tag`, `r` and `s` by `attribute!`, the text of
# `<v>` by `simple_value!`.
const ON_TRIAL = isdefined(XML, :attribute!)
if ON_TRIAL
    @eval function walk_trial(s)
        c = Cursor(s)
        acc = 0
        while next!(c) !== nothing
            nodetype(c) === XML.Element || continue
            if XML.is_tag(c, "c")
                r, st = XML.attribute!(c, "r", "s")
                r === nothing || (acc += ncodeunits(r))
                st === nothing || (acc += ncodeunits(st))
            elseif XML.is_tag(c, "v")
                v = XML.simple_value!(c)
                v === nothing || (acc += ncodeunits(v))
            end
        end
        return acc
    end
end

# A byte scan written for this one shape, without XML.jl: the attributes `r` and `s` of each
# `<c>`, and the text of its `<v>`.
function scan_shape(s::String)
    u = codeunits(s)
    n = length(u)
    acc = 0
    i = 1
    @inbounds while true
        i = something(findnext(==(0x3c), u, i), 0)
        i == 0 && break
        if i + 2 <= n && u[i+1] == UInt8('c') && u[i+2] == 0x20
            j = i + 3
            while u[j] != UInt8('>')
                k = j
                while u[j] != UInt8('=')
                    j += 1
                end
                q = u[j+1]
                e = something(findnext(==(q), u, j + 2), 0)
                (j - k == 1 && (u[k] == UInt8('r') || u[k] == UInt8('s'))) && (acc += e - (j + 2))
                j = e + 1
                while u[j] == 0x20
                    j += 1
                end
            end
            if j + 3 <= n && u[j+1] == 0x3c && u[j+2] == UInt8('v') && u[j+3] == UInt8('>')
                e = something(findnext(==(0x3c), u, j + 4), 0)
                acc += e - (j + 4)
                j = e
            end
            i = j + 1
        else
            i += 1
        end
    end
    return acc
end

readings = Pair{String, Function}[
    "next! alone" => walk_next,
    "eachattribute!, is_simple_value, skip_element!" => walk_each,
    "get twice, is_simple_value, skip_element!" => walk_get,
]
ON_TRIAL && push!(readings, "is_tag, attribute!, simple_value!" => walk_trial)
push!(readings, "byte scan written for this shape" => scan_shape)

@assert allequal(f(SHEET) for (name, f) in readings if f !== walk_next)
println("XML.jl ", pkgversion(XML), " ; Julia ", VERSION, " ; ", Sys.cpu_info()[1].model, " ; ",
        NCELLS, " cells, ", ncodeunits(SHEET), " bytes")
for (name, f) in readings
    t = @benchmark $f($SHEET) samples = 30 evals = 1 seconds = 20
    println(rpad(name, 48), lpad(round(median(t).time / NCELLS; digits = 1), 7), " ns per cell (median) ; ",
            t.allocs, " allocations for the sheet")
end
