# FFI for Data.SystemSpec — Tier-2 increment 2.
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
compileFieldJ(stateVars) = paramVars -> jexprs -> () -> begin
    allvars = Any[v for v in stateVars]
    for v in paramVars
        Base.push!(allvars, v)
    end
    params = Base.Expr(:tuple, [Base.Symbol(v) for v in allvars]...)
    fns = Any[RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Base.Expr(:->, params, je)) for je in jexprs]
    (fns, Base.length(stateVars))
end

# integrateJ field s0 ps dt steps : Effect (Array (Array Number))
# Native RK4; the RHS functions are RGFs, so they are called directly — both the
# RHS bodies and the integration arithmetic are native Julia.
integrateJ(field) = s0 -> ps -> dt -> steps -> () -> begin
    fns = field[1]
    state = Base.Float64[x for x in s0]
    pvals = Base.Float64[x for x in ps]
    rhs = function (st)
        args = Base.vcat(st, pvals)
        Base.Float64[f(args...) for f in fns]
    end
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
