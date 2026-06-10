# FFI for Data.SystemSpec.Julia — Tier-2 increment 2.
#
# Compile a system's RHS expressions (already folded to Julia Exprs on the PS
# side) into native functions over (stateVars..., paramVars...), then integrate
# the resulting vector field with a native RK4 loop. Field == (fns, nstate);
# the PS phantom rows are erased here.
#
# The RHS functions are RuntimeGeneratedFunctions: native and specializing, with
# no world-age boundary, so the RK4 inner loop calls them directly (no
# `invokelatest`) — ADR-0007.

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

# compileFieldJ stateVars paramVars jexprs : Effect (Field s p)
# Builds ONE fused RGF  (s, p) -> Float64[rhs₁, rhs₂, …]  : the per-equation
# Exprs are spliced into a single typed-vector body inside a `let` that binds
# each state/param name to its positional slot in the state/param vectors.
#
# This deliberately avoids the obvious shape — N per-equation RGFs in a
# Vector{Any} called as `Float64[f(args...) for f in fns]`. That shape pays a
# dynamic dispatch (Vector{Any}) plus a runtime-length splat on every RHS
# evaluation and benchmarks ~21× slower than hand-written Julia. The single
# fused RGF is concretely typed and splat-free; it matches hand-written Julia to
# ~1.00× (`bench/overhead.jl`) — so the typed PureScript description costs
# nothing in the hot loop (ADR-0007: the seam is crossed once, at staging).
compileFieldJ(stateVars) = paramVars -> jexprs -> () -> begin
    binds = Base.Any[]
    for i in 1:Base.length(stateVars)
        Base.push!(binds, Base.Expr(:(=), Base.Symbol(stateVars[i]), Base.Expr(:ref, :s, i)))
    end
    for j in 1:Base.length(paramVars)
        Base.push!(binds, Base.Expr(:(=), Base.Symbol(paramVars[j]), Base.Expr(:ref, :p, j)))
    end
    arraybody = Base.Expr(:ref, Base.Float64, jexprs...)         # Float64[je₁, je₂, …]
    letbody = Base.Expr(:let, Base.Expr(:block, binds...), arraybody)
    lambda = Base.Expr(:->, Base.Expr(:tuple, :s, :p), letbody)  # (s, p) -> let …; Float64[…] end
    fused = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(lambda)
    (fused, Base.length(stateVars))
end

# integrateJ field s0 ps dt steps : Effect (Array (Array Number))
# Native RK4; the RHS is the single fused RGF, called directly with the state and
# param vectors (no splat, no dynamic dispatch) — both the RHS bodies and the
# integration arithmetic are native Julia.
integrateJ(field) = s0 -> ps -> dt -> steps -> () -> begin
    fused = field[1]
    state = Base.Float64[x for x in s0]
    pvals = Base.Float64[x for x in ps]
    rhs = st -> fused(st, pvals)
    out = Any[]
    for _ in 1:steps
        k1 = rhs(state)
        k2 = rhs(state .+ (dt / 2) .* k1)
        k3 = rhs(state .+ (dt / 2) .* k2)
        k4 = rhs(state .+ dt .* k3)
        state = state .+ (dt / 6) .* (k1 .+ 2 .* k2 .+ 2 .* k3 .+ k4)
        Base.push!(out, Any[x for x in state])
    end
    out
end
