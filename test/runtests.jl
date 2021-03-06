using Test, Printf

t1 = @elapsed using Tullio
@info @sprintf("Loading Tullio took %.1f seconds", t1)

@info "Testing with $(Threads.nthreads()) threads"
if Threads.nthreads() > 1 # use threading even on small arrays
    Tullio.BLOCK[] = 32
    Tullio.TILE[] = 32
end

is_buildkite = parse(Bool, get(ENV, "BUILDKITE", "false"))
if is_buildkite
    test_group = "2" # if this is Buildkite, we only run group 2
else
    test_group = get(ENV, "TULLIO_TEST_GROUP", "all")
end
@info "" test_group is_buildkite

if test_group in ["all", "1"]
    include("group-1.jl")
end
if test_group in ["all", "2"]
    include("group-2.jl")
end
if test_group in ["all", "3"]
    include("group-3.jl")
end
