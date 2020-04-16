
#========== backward gradient using symbolic derivatives ==========#

using DiffRules

function insert_base_gradient(create, apply!, store)
    store.verbose && @info "using symbolic gradient for: $create ~ $(store.right[])"

    dZ = Symbol(DEL, ZED)
    ∇apply! = Symbol(:∇, apply!)
    gradarrays = map(A -> Symbol(DEL, A), store.arrays)

    nonshared = setdiff(vcat(store.leftind, store.redind), store.sharedind)

    # loopind = vcat(store.leftind, store.redind)
    # shared = map(i -> Symbol(AXIS, i), store.sharedind)
    # nonshared = map(i -> Symbol(AXIS, i), setdiff(loopind, store.sharedind))
    axislist = map(i -> Symbol(AXIS, i), vcat(store.sharedind, nonshared))

    targets=[]
    MacroTools_postwalk(symbwalk(targets), store.right[])
    unique!(targets)
    inbody = map(targets) do (dt, t)
        drdt = leibnitz(store.right[], t)
        deltar = simplitimes(drdt, :($dZ[$(store.leftraw...)]))
        :($dt = $dt + $deltar)
    end
    ex_body = commonsubex(quote $(inbody...) end)

    make_many_workers(∇apply!,
        vcat(gradarrays, :($dZ::AbstractArray{$TYP}), store.arrays, store.scalars, axislist),
        nothing, store.sharedind, nothing, nonshared, ex_body, nothing, store)

end

# This could probably use https://github.com/dfdx/XGrad.jl
# or https://github.com/SciML/ModelingToolkit.jl
# but seemed simple enough to just write out, using rules from:
# http://www.juliadiff.org/DiffRules.jl/latest/

symbwalk(targets) = ex -> begin
        @capture_(ex, A_[inds__]) && A isa Symbol || return ex
        deltaex = :($(Symbol(DEL, A))[$(inds...)])
        push!(targets, (deltaex, ex))
        return ex
    end

leibnitz(s::Number, target) = 0
leibnitz(s::Symbol, target) = s == target ? 1 : 0
leibnitz(ex::Expr, target) = begin
    ex == target && return 1
    @capture_(ex, B_[ijk__]) && return 0
    if ex.head == Symbol("'")
        ex.head = :call
        pushfirst!(ex.args, :adjoint)
    end
    ex.head == :call || error("expected a functionn call, got $ex. Use @tullio grad=false if you do not need the gradient.")
    fun = ex.args[1]
    if length(ex.args) == 2 # one-arg function
        fx = mydiffrule(fun, ex.args[2])
        dx = leibnitz(ex.args[2], target)
        return simplitimes(fx, dx)
    elseif length(ex.args) == 3  # two-arg function
        fx, fy = mydiffrule(fun, ex.args[2:end]...)
        dx = leibnitz(ex.args[2], target)
        dy = leibnitz(ex.args[3], target)
        return simpliplus(simplitimes(fx, dx), simplitimes(fy, dy))
    elseif fun in [:+, :*]
        fun == :* && return leibnitz(:(*($(ex.args[2]), *($(ex.args[3:end]...)))), target)
        dxs = [leibnitz(x, target) for x in ex.args[2:end]]
        fun == :+ && return simpliplus(dxs...)
    end
    error("don't know how to handle $ex. Use @tullio grad=false if you do not need the gradient.")
end

simplitimes(x::Number, y::Number) = x*y
simplitimes(x::Number, y) = x==0 ? 0 : x==1 ? y : x==-1 ? :(-$y) : :($x * $y)
simplitimes(x, y::Number) = y==0 ? 0 : y==1 ? x : y==-1 ? :(-$x) : :($y * $x)
simplitimes(x, y) = :($y * $x)

simpliplus(x::Number, y::Number) = x + y
simpliplus(x::Number, y) = x==0 ? y : :($x + $y)
simpliplus(x, y::Number) = y==0 ? x : :($x + $y)
simpliplus(x, y) = :($x + $y)
simpliplus(x, y, zs...) = simpliplus(simpliplus(x, y), zs...)

mydiffrule(f, xs...) = begin
    f == :+ && return map(_->1, xs)
    f == :- && return length(xs)==1 ? -1 : (1,-1)
    f == :^ && return mypowrule(xs...)
    f == :/ || f== :// && return mydivrule(xs...)
    f == :log && return simpliinv(xs...)
    f == :trunc && return map(_->0, xs)
    DiffRules.hasdiffrule(:Base, f, length(xs)) &&
        return DiffRules.diffrule(:Base, f, xs...)
    DiffRules.hasdiffrule(:SpecialFunctions, f, length(xs)) &&
        return DiffRules.diffrule(:SpecialFunctions, f, xs...)
    error("no diffrule found for function $f($(join(map(_->"_",xs),", "))). Use @tullio grad=false if you do not need the gradient.")
end

mydivrule(x, y) = simpliinv(y), :( -$x / ($y * $y) ) # (:(one(x) / y), :(-((x / y) / y)))
mydivrule(x, y::Integer) = (y==1 ? 1 : 1//y), 0
mydivrule(x, y::Number) = (y==1 ? 1 : :(one($TYP)/$y)), 0

simpliinv(x::Expr) = if x.head == :call && x.args[1] == :/
        :($(x.args[3]) / $(x.args[2]))
    else
        :(one($TYP) / $x)
    end

mypowrule(x, p) = simplitimes(p, simplipow(x, simpliplus(p, -1))), simplitimes(simplipow(x,p), :(log($x)))

simplipow(x::Number, p::Number) = x^p
simplipow(x, p::Number) = p==1 ? x : p==2 ? :($x*$x) : :($x^$p)
simplipow(x, p) = :($x^$p)

function commonsubex(expr::Expr)
    seen = Expr[]
    twice = Dict{Expr,Symbol}()
    MacroTools_postwalk(expr) do ex
        if ex in keys(twice)
            return ex
        elseif ex in seen
            twice[ex] = Symbol(string(ex))
            return ex
        elseif ex isa Expr && ex.head != :ref # && !(ex.head in [:+, :-, :*])
            push!(seen, ex)
        # elseif ex isa Expr && ex.head == :ref
        #     return nothing
        # trying to prevent pulling out [i+j-1] etc, but needs prewalk, which is worse?
        end
        ex
    end
    rules = Dict{Expr,Symbol}()
    out = commonapply(expr, twice, rules)
    for (ex,sy) in pairs(rules)
        pushfirst!(out.args, :($sy = $ex))
    end
    out
end

commonapply(expr, twice, rules) =
    MacroTools.prewalk(expr) do ex
        ex == expr && return ex
        if ex in keys(twice)
            sy = twice[ex]
            rules[ex] = sy
            return sy
        end
        ex
    end

#========== the end ==========#
