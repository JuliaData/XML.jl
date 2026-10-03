# The W3C XML Conformance Test Suite is not kept in the repository: it is downloaded once into
# `test/data/w3c`. `suite.jl` fetches it before its first testset, since several walk the
# fixtures on disk; `test_w3c.jl` includes this file itself when it runs alone.

using Downloads: download
using Tar

const W3C_URL = "https://www.w3.org/XML/Test/xmlts20130923.tar"
const W3C_DIR = joinpath(@__DIR__, "data", "w3c")
const W3C_TAR = joinpath(@__DIR__, "data", "xmlts20130923.tar")

function ensure_w3c_suite()
    isdir(joinpath(W3C_DIR, "xmlconf")) && return
    mkpath(W3C_DIR)
    if !isfile(W3C_TAR)
        @info "Downloading W3C XML Conformance Test Suite..."
        download(W3C_URL, W3C_TAR)
    end
    @info "Extracting W3C XML Conformance Test Suite..."
    open(W3C_TAR) do io
        Tar.extract(io, W3C_DIR)
    end
end
