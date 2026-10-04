module EofReader
using XML

function line_count(io)
    count = 0
    while !eof(io)
        readline(io)
        count += 1
    end
    return count
end

function cursor_states(text)
    cursor = parse(Cursor, text)
    states = Bool[eof(cursor)]
    while next!(cursor) !== nothing
        push!(states, eof(cursor))
    end
    push!(states, eof(cursor))
    return states
end
end

module ImportedEofReader
using XML: eof
at_end(x) = eof(x)
end

@testset "Base EOF binding and reader imports" begin
    @test XML.eof === Base.eof
    @test EofReader.line_count(IOBuffer("a\nb\n")) == 2
    @test EofReader.line_count(IOBuffer("")) == 0
    @test EofReader.cursor_states("") == Bool[false, true]
    @test EofReader.cursor_states("<r/>") == Bool[false, false, true]
    @test EofReader.cursor_states("<r><a/></r>") == Bool[false, false, false, true]
    for at_end in (Base.eof, XML.eof, ImportedEofReader.at_end)
        @test at_end(IOBuffer(""))
        @test !at_end(IOBuffer("x"))
        for doc in ("", "<r/>", "<r><a/></r>")
            cursor = parse(XML.Cursor, doc)
            @test !at_end(cursor)
            while XML.next!(cursor) !== nothing
            end
            @test at_end(cursor)
            @test XML.next!(cursor) === nothing
            @test at_end(cursor)
        end
    end
end
