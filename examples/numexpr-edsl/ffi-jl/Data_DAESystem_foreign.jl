# FFI for Data.DAESystem — Tier-2 increment 4 (differential-algebraic systems).
#
# Same seam as increments 1–3 (ADR-0002): PureScript hands across ordered
# variable names plus one RHS `JExpr` per equation (Julia `Expr`s over bare
# `Symbol`s, already folded through the Data.NumExpr builders — the shim never
# destructures a PureScript ADT). Here Julia denotes a *differential-algebraic*
# system into ModelingToolkit:
#
#   - state variables (differential) and algebraic variables are BOTH functions
#     of t (callable `@variables x(t)`); only the algebraic ones lack a `D(·)`
#     equation. Parameters are plain (non-callable) Symbolics variables.
#   - equations = [D(state_i) ~ diffRhs_i] ++ [0 ~ constraint_j].
#   - `mtkcompile` produces an index-1 DAE (the algebraic variables stay as
#     unknowns, closed by the constraint equations); `Rodas5P` — an implicit
#     stiff solver — integrates it, holding the algebraic constraints by Newton
#     iteration at every step (a plain ODE solver cannot).
#
# Every library call is qualified: this file is `include`d *inside* the generated
# `Data_DAESystem` module, where PureScript-defined names (`solveDAE`,
# `sampleColumns`, …) would otherwise shadow library functions.
#
# Validated against ModelingToolkit v11 / Symbolics v7 / OrdinaryDiffEq v7. Note
# the coordinate-singularity hazard for Cartesian mechanical DAEs: full
# automatic index reduction to an ODE divides by a chosen coordinate (singular at
# the pendulum's vertical), so the *acceleration-level* constraint form is used,
# which keeps the tensions as nonsingular algebraic unknowns (x²+y² = L² ≠ 0).
#
#   DAEField handle    == (sys, sts, algs, ps, varmap) — simplified System,
#                         state/alg/param symbolic vars, name→sym map
#   DAESolution handle == (sol, varmap)                — ODESolution + name→sym
#   Effect a           == zero-arg thunk

import ModelingToolkit
import OrdinaryDiffEq
import Symbolics

const _JURIST_IV = ModelingToolkit.t_nounits
const _JURIST_D = ModelingToolkit.D_nounits

# Callable variables (state + algebraic), in order, via the `@variables x(t)…`
# macro — the only construction Symbolics v7 accepts for callable variables.
function _jurist_callable_vars(names)
    decls = Base.Any[Base.Expr(:call, Base.Symbol(n), :t) for n in names]
    varmacro = Base.Expr(:macrocall,
        Base.Expr(:., :Symbolics, Base.QuoteNode(Base.Symbol("@variables"))),
        Base.LineNumberNode(0, :none),
        decls...)
    letexpr = Base.Expr(:let, Base.Expr(:block, Base.Expr(:(=), :t, _JURIST_IV)), varmacro)
    Base.collect(Base.eval(@__MODULE__, letexpr))
end

# Bind each name to its symbolic var in a `let`, then eval the RHS Expr so the
# bare Symbols resolve and `+`/`*`/`/`/… build symbolic terms.
function _jurist_denote(jexpr, names, syms)
    assigns = Base.Any[]
    for i in Base.eachindex(names)
        Base.push!(assigns, Base.Expr(:(=), Base.Symbol(names[i]), syms[i]))
    end
    letblk = Base.Expr(:let, Base.Expr(:block, assigns...), jexpr)
    Base.eval(@__MODULE__, letblk)
end

# buildDAEFieldJ stateVars algVars paramVars diffJexprs consJexprs : Effect (DAEField s a p)
buildDAEFieldJ(stateVars) = algVars -> paramVars -> diffJexprs -> consJexprs -> () -> begin
    stsyms = _jurist_callable_vars(stateVars)
    algsyms = _jurist_callable_vars(algVars)
    psyms = Base.Any[Symbolics.variable(Base.Symbol(n)) for n in paramVars]

    allnames = Base.vcat(Base.collect(stateVars), Base.collect(algVars), Base.collect(paramVars))
    allsyms = Base.vcat(stsyms, algsyms, psyms)

    diffrhs = Base.Any[_jurist_denote(je, allnames, allsyms) for je in diffJexprs]
    consexp = Base.Any[_jurist_denote(je, allnames, allsyms) for je in consJexprs]

    # Comprehensions (not Any[]+push!) so eqs is a typed Vector{Equation}, which
    # is what `System` dispatches on.
    diffeqs = [_JURIST_D(stsyms[i]) ~ diffrhs[i] for i in 1:Base.length(stsyms)]
    conseqs = [0 ~ consexp[j] for j in 1:Base.length(consexp)]
    eqs = Base.vcat(diffeqs, conseqs)

    unknowns = Base.vcat(stsyms, algsyms)
    sys = ModelingToolkit.System(eqs, _JURIST_IV, unknowns, psyms; name = :jurist_dae)
    simp = ModelingToolkit.mtkcompile(sys)

    varmap = Base.Dict{Base.String,Base.Any}()
    for i in 1:Base.length(stateVars); varmap[Base.String(stateVars[i])] = stsyms[i]; end
    for i in 1:Base.length(algVars); varmap[Base.String(algVars[i])] = algsyms[i]; end

    (sys = simp, sts = stsyms, algs = algsyms, ps = psyms, varmap = varmap)
end

# simplifiedEquationsSourceJ field : Effect String
simplifiedEquationsSourceJ(field) = () -> begin
    eqs = ModelingToolkit.equations(field.sys)
    Base.join([Base.string(e) for e in eqs], "\n")
end

# solveDAEJ field s0 aGuess ps t0 t1 : Effect DAESolution
# Differential ICs in u0; algebraic-variable guesses for the consistent-init
# solve; parameters in the operating-point map. Rodas5P is an implicit stiff
# integrator able to hold the algebraic constraints of the index-1 DAE.
solveDAEJ(field) = s0 -> aGuess -> ps -> t0 -> t1 -> () -> begin
    u0 = Base.Dict(field.sts[i] => Base.Float64(s0[i]) for i in 1:Base.length(field.sts))
    pmap = Base.Dict(field.ps[i] => Base.Float64(ps[i]) for i in 1:Base.length(field.ps))
    guesses = Base.Dict(field.algs[i] => Base.Float64(aGuess[i]) for i in 1:Base.length(field.algs))
    op = Base.merge(u0, pmap)
    tspan = (Base.Float64(t0), Base.Float64(t1))
    prob = ModelingToolkit.ODEProblem(field.sys, op, tspan; guesses = guesses)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Rodas5P(); reltol = 1e-9, abstol = 1e-9)
    (sol = sol, varmap = field.varmap)
end

# sampleColumnsJ sol names times : Effect (Array (Array Number))
# Dense-output interpolation at each time, columns by symbolic identity (robust
# to any internal reordering by mtkcompile).
sampleColumnsJ(sol) = names -> times -> () -> begin
    cols = Base.Any[sol.varmap[Base.String(n)] for n in names]
    Base.Any[Base.Any[sol.sol(Base.Float64(t); idxs = c) for c in cols] for t in times]
end

# dumpFramesJSONJ sol names times meta path : Effect Unit
# Sample the named columns at the given times and write a JSON file directly —
# the bulk animation data stays Julia-owned until it lands on disk. `meta` is a
# raw JSON object body (no braces), e.g. "\"L1\":1.0,\"L2\":1.0".
dumpFramesJSONJ(sol) = names -> times -> meta -> path -> () -> begin
    cols = Base.Any[sol.varmap[Base.String(n)] for n in names]
    io = Base.IOBuffer()
    Base.print(io, "{")
    if Base.length(meta) > 0
        Base.print(io, meta, ",")
    end
    Base.print(io, "\"vars\":[", Base.join(["\"" * Base.String(n) * "\"" for n in names], ","), "],")
    Base.print(io, "\"times\":[", Base.join([Base.string(Base.Float64(t)) for t in times], ","), "],")
    Base.print(io, "\"frames\":[")
    for (k, t) in Base.enumerate(times)
        row = [Base.string(sol.sol(Base.Float64(t); idxs = c)) for c in cols]
        Base.print(io, "[", Base.join(row, ","), "]")
        if k < Base.length(times); Base.print(io, ","); end
    end
    Base.print(io, "]}")
    Base.write(path, Base.String(Base.take!(io)))
    ()
end
