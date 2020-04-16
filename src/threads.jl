
#========== cost "model" ==========#

BLOCK = Ref(5001)
# matmul: 1_000 < length < 10_000
# batchmul: 1_000 < length < 27_000
# log: crossover about length 10_000

COSTS = Dict(:* => 1, :/ => 2, :log => 1, :exp => 1) # plus 1 initially

callcost(sy, store) =
    if haskey(COSTS, sy)
        store.cost[] += COSTS[sy]
    end

# Then block = BLOCK[] ÷ store.cost[] is the number of iterations at which threading is turned on.

#========== runtime functions ==========#

"""
    threader(f!,T, Z, (A,B), (1:5,1:6), (1:7), 100)

Calling `f!(T, Z,A,B, 1:5,1:6, 1:7)` should do the work.
But if there are enough elements (meaning `5*6*7 > 100`)
then this will call `f!` many times in different threads.

The first tuple of ranges are supposed to be safe to thread over,
probably the axes of the output `Z`.
It will subdivide the longest until either there are too few elements,
or it has spent its spawning budget, `2*nthreads()`.

For a scalar reduction the first tuple will be empty, and `length(Z)==1`.
Then it divides up the other axes, each accumulating in its own copy of `Z`,
and in this case the spawning budget is `nthreads()`.
"""
function threader(fun!::Function, T::Type, Z::AbstractArray, As::Tuple, Is::Tuple, Js::Tuple, block::Int)
    if Threads.nthreads() == 1
        fun!(T, Z, As..., Is..., Js...)
    elseif length(Is) >= 1
        thread_halves(fun!, T, (Z, As...), Is, Js, block, 2*Threads.nthreads())
    elseif length(Z) == 1 && eltype(Z) <: Number
        thread_scalar(fun!, T, Z, As, Js, block, Threads.nthreads())
    else
        fun!(T, Z, As..., Is..., Js...)
    end
end

"""
    ∇threader(f!,T, (dA,dB,dZ,A,B), (1:5), (1:6,1:7), 100)

Again, calling `f!(T, dA,dB,dZ,A,B, 1:5,1:6, 1:7)` should do the work.

The first tuple of ranges should be safe to thread over, e.g. those in common
to all output arrays. If there are none, then it takes a second strategy
of dividing up the other ranges into blocks disjoint in every index,
and giving those to different threads.
"""
function ∇threader(fun!::Function, T::Type, As::Tuple, Is::Tuple, Js::Tuple, block::Int)
    if Threads.nthreads() == 1
        fun!(T, As..., Is..., Js...)
    elseif length(Is) >= 1
        thread_halves(fun!, T, As, Is, Js, block, 2*Threads.nthreads())
    else
        thread_quarters(fun!, T, As, Js, block, 2*Threads.nthreads())
    end
end

function thread_halves(fun!::Function, T::Type, As::Tuple, Is::Tuple, Js::Tuple, block::Int, spawns::Int)
    if productlength(Is,Js) <= block || productlength(Is) <= 2 || spawns < 2
        # @info "thread_halves on $(Threads.threadid())" Is Js
        return fun!(T, As..., Is..., Js...)
    else
        I1s, I2s = cleave(Is)
        # if spawns >= 2
            Base.@sync begin
                Threads.@spawn thread_halves(fun!, T, As, I1s, Js, block, div(spawns,2))
                Threads.@spawn thread_halves(fun!, T, As, I2s, Js, block, div(spawns,2))
            end
        # else
        #     thread_halves(fun!, T, As, I1s, Js, block, 0)
        #     thread_halves(fun!, T, As, I2s, Js, block, 0)
        # end
    end
end

function thread_scalar(fun!::Function, T::Type, Z::AbstractArray, As::Tuple, Js::Tuple, block::Int, spawns::Int)
    if productlength(Js) <= block || spawns < 2
        # @info "thread_scalar on $(Threads.threadid())" Js
        return fun!(T, Z, As..., Js...)
    else
        Z1, Z2 = similar(Z), similar(Z)
        J1s, J2s = cleave(Js)
        Base.@sync begin
            Threads.@spawn thread_scalar(fun!, T, Z1, As, J1s, block, div(spawns,2))
            Threads.@spawn thread_scalar(fun!, T, Z2, As, J2s, block, div(spawns,2))
        end
        Z .= Z1 .+ Z2
    end
end

function thread_quarters(fun!::Function, T::Type, As::Tuple, Js::Tuple, block::Int, spawns::Int)
    if productlength(Js) <= block || count(r -> length(r)>=2, Js) < 2 || spawns < 4
        return fun!(T, As..., Js...)
    else
        Q11, Q12, Q21, Q22 = quarter(Js)
        Base.@sync begin
            Threads.@spawn thread_quarters(fun!, T, As, Q11, block, div(spawns,4))
            Threads.@spawn thread_quarters(fun!, T, As, Q22, block, div(spawns,4))
        end
        Base.@sync begin
            Threads.@spawn thread_quarters(fun!, T, As, Q12, block, div(spawns,4))
            Threads.@spawn thread_quarters(fun!, T, As, Q21, block, div(spawns,4))
        end
    end
end

productlength(Is::Tuple) = prod(length.(Is))
productlength(Is::Tuple, Js::Tuple) = productlength(Is) * productlength(Js)

"""
    cleave((1:10, 1:20, 5:15)) -> lo, hi
Picks the longest of a tuple of ranges, and divides that one in half.
"""
function cleave(ranges::Tuple{Vararg{<:AbstractUnitRange,N}}, step::Int=4) where {N}
    c::Int, long::Int = 0, 0
    ntuple(Val(N)) do i
        li = length(ranges[i])
        if li > long
            c = i
            long = li
        end
    end
    cleft = if long >= 2*step
        minimum(ranges[c]) - 1 + step * div(long, step * 2)
    else
        minimum(ranges[c]) - 1 + div(long, 2)
    end
    alpha = ntuple(Val(N)) do i
        ri = ranges[i]
        ifelse(i == c,  minimum(ri):cleft, minimum(ri):maximum(ri))
    end
    beta = ntuple(Val(N)) do i
        ri = ranges[i]
        ifelse(i == c, cleft+1:maximum(ri), minimum(ri):maximum(ri))
    end
    return alpha, beta
end
cleave(::Tuple{}, n::Int=4) = (), ()

"""
    quarter((1:10, 1:20, 3:4)) -> Q11, Q12, Q21, Q22
Picks the longest two ranges, divides each in half, and returns the four quadrants.
"""
function quarter(ranges::Tuple{Vararg{<:AbstractUnitRange,N}}, step::Int=4) where {N}
    c::Int, long::Int = 0, 0
    ntuple(Val(N)) do i
        li = length(ranges[i])
        if li > long
            c = i
            long = li
        end
    end
    d::Int, second::Int = 0,0
    ntuple(Val(N)) do j
        j == c && return
        lj = length(ranges[j])
        if lj > second
            d = j
            second = lj
        end
    end

    cleft = if long >= 2*step
        minimum(ranges[c]) - 1 + step * div(long, step * 2)
    else
        minimum(ranges[c]) - 1 + div(long, 2)
    end
    delta = if second >= 2*step
        minimum(ranges[d]) - 1 + step * div(second, step * 2)
    else
        minimum(ranges[d]) - 1 + div(second, 2)
    end

    Q11 = ntuple(Val(N)) do i
        ri = ranges[i]
        (i == c) ? (minimum(ri):cleft) : (i==d) ? (minimum(ri):delta) : (minimum(ri):maximum(ri))
    end
    Q12 = ntuple(Val(N)) do i
        ri = ranges[i]
        (i == c) ? (minimum(ri):cleft) : (i==d) ? (delta+1:maximum(ri)) : (minimum(ri):maximum(ri))
    end
    Q21 = ntuple(Val(N)) do i
        ri = ranges[i]
        (i == c) ? (cleft+1:maximum(ri)) : (i==d) ? (minimum(ri):delta) : (minimum(ri):maximum(ri))
    end
    Q22 = ntuple(Val(N)) do i
        ri = ranges[i]
        (i == c) ? (cleft+1:maximum(ri)) : (i==d) ? (delta+1:maximum(ri)) : (minimum(ri):maximum(ri))
    end
    return Q11, Q12, Q21, Q22
end

#========== the end ==========#
