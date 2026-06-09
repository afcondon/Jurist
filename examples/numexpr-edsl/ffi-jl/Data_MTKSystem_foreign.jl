# FFI for Data.MTKSystem — Tier-2 increment 3 (ModelingToolkit denotation).
#
# Same seam as increments 1 & 2 (ADR-0002): PureScript hands across ordered
# variable names plus one RHS `JExpr` per state equation (a Julia `Expr` over
# bare `Symbol`s, already folded through the Data.NumExpr builders — the shim
# never destructures a PureScript ADT). Here Julia *denotes* those descriptions
# into ModelingToolkit: the names become Symbolics variables, the Exprs are
# evaluated against them into a symbolic `System`, MTK simplifies it and derives
# the analytic Jacobian, and SciML's default adaptive solver — a polyalgorithm
# that auto-switches to a stiff method (Rosenbrock/FBDF) when it detects
# stiffness — integrates it using that Jacobian.
#
# Every library call is qualified: this file is `include`d *inside* the
# generated `Data_MTKSystem` module, where the PureScript-defined `solve`,
# `equations`, etc. would otherwise shadow the library functions of the same
# name (README "Qualify Base. for anything your shim calls if the module
# shadows it" — the same hazard, here against ModelingToolkit/OrdinaryDiffEq).
#
# API note (validated against ModelingToolkit v11 / Symbolics v7 / OrdinaryDiffEq
# v7): state variables must be created via the `@variables x(t)` macro (the
# functional `variable(; T=FnType)` path was removed); the system constructor is
# `System` with explicit unknowns/params (`ODESystem` is deprecated and
# auto-misclassifies params); `mtkcompile` replaces `structural_simplify`;
# `ODEProblem` takes a single merged operating-point map; and — crucially —
# `mtkcompile` may REORDER the unknowns, so results are read back by *symbolic
# index* (`sol[var]`, `sol(t; idxs=var)`), never positionally.
#
#   MTKField handle == (sys, sts, ps) — simplified System + symbolic vars
#                                       (sts in PureScript-declared order)
#   Solution handle == (sol, sts)     — ODESolution + the same symbolic vars
#   Effect a        == zero-arg thunk

import ModelingToolkit
import OrdinaryDiffEq
import Symbolics

const _JURIST_IV = ModelingToolkit.t_nounits
const _JURIST_D = ModelingToolkit.D_nounits

# Create the state variables as functions of t, in the given order, via the
# `@variables x(t) y(t) …` macro (the only construction Symbolics v7 accepts for
# callable variables). Built as a qualified macrocall Expr and eval'd in a `let`
# that binds the independent variable.
function _jurist_state_vars(names)
    decls = Base.Any[Base.Expr(:call, Base.Symbol(n), :t) for n in names]
    varmacro = Base.Expr(:macrocall,
        Base.Expr(:., :Symbolics, Base.QuoteNode(Base.Symbol("@variables"))),
        Base.LineNumberNode(0, :none),
        decls...)
    letexpr = Base.Expr(:let, Base.Expr(:block, Base.Expr(:(=), :t, _JURIST_IV)), varmacro)
    Base.collect(Base.eval(@__MODULE__, letexpr))
end

# Evaluate a RHS Expr against the symbolic variables: bind each name to its
# symbolic var in a `let`, then eval, so the bare Symbols in the Expr resolve and
# `+`/`*`/… build symbolic terms.
function _jurist_denote(jexpr, names, syms)
    assigns = Base.Any[]
    for i in Base.eachindex(names)
        Base.push!(assigns, Base.Expr(:(=), Base.Symbol(names[i]), syms[i]))
    end
    letblk = Base.Expr(:let, Base.Expr(:block, assigns...), jexpr)
    Base.eval(@__MODULE__, letblk)
end

# buildFieldJ stateVars paramVars jexprs : Effect (MTKField s p)
buildFieldJ(stateVars) = paramVars -> jexprs -> () -> begin
    stsyms = _jurist_state_vars(stateVars)
    psyms = Base.Any[Symbolics.variable(Base.Symbol(n)) for n in paramVars]
    allnames = Base.vcat(Base.collect(stateVars), Base.collect(paramVars))
    allsyms = Base.vcat(stsyms, psyms)
    rhs = Base.Any[_jurist_denote(je, allnames, allsyms) for je in jexprs]
    eqs = [_JURIST_D(stsyms[i]) ~ rhs[i] for i in 1:Base.length(stsyms)]
    sys = ModelingToolkit.System(eqs, _JURIST_IV, stsyms, psyms; name = :jurist_sys)
    simp = ModelingToolkit.mtkcompile(sys)
    (sys = simp, sts = stsyms, ps = psyms)
end

# equationsSourceJ field : Effect String
equationsSourceJ(field) = () -> begin
    eqs = ModelingToolkit.equations(field.sys)
    Base.join([Base.string(e) for e in eqs], "\n")
end

# jacobianSourceJ field : Effect String
# The analytic Jacobian of the RHS wrt the state variables — derived
# symbolically by MTK from the PureScript-described system. Rendered row by row
# (Base.string on the whole matrix prepends a noisy element-type annotation).
jacobianSourceJ(field) = () -> begin
    J = ModelingToolkit.calculate_jacobian(field.sys)
    nrows = Base.size(J, 1)
    ncols = Base.size(J, 2)
    lines = Base.String[]
    for i in 1:nrows
        cells = [Base.string(J[i, j]) for j in 1:ncols]
        Base.push!(lines, "  [ " * Base.join(cells, ",  ") * " ]")
    end
    Base.join(lines, "\n")
end

# solveJ field s0 ps t0 t1 : Effect Solution
# u0 and parameters cross as a single merged operating-point map (v11 form).
# The default solver is a stiffness-auto-switching polyalgorithm; it uses the
# analytic Jacobian (jac=true).
solveJ(field) = s0 -> ps -> t0 -> t1 -> () -> begin
    u0 = Base.Dict(field.sts[i] => Base.Float64(s0[i]) for i in 1:Base.length(field.sts))
    pmap = Base.Dict(field.ps[i] => Base.Float64(ps[i]) for i in 1:Base.length(field.ps))
    op = Base.merge(u0, pmap)
    tspan = (Base.Float64(t0), Base.Float64(t1))
    prob = ModelingToolkit.ODEProblem(field.sys, op, tspan; jac = true)
    sol = OrdinaryDiffEq.solve(prob)
    (sol = sol, sts = field.sts)
end

# sampleAtJ sol times : Effect (Array (Array Number))
# Dense-output interpolation at the requested times, read by symbolic index so
# the rows come back in PureScript-declared state order regardless of any
# internal reordering by mtkcompile.
sampleAtJ(sol) = times -> () -> begin
    Base.Any[Base.Any[sol.sol(Base.Float64(t); idxs = v) for v in sol.sts] for t in times]
end

# finalStateJ sol : Effect (Array Number)  (PS-declared order)
finalStateJ(sol) = () -> begin
    tf = sol.sol.t[Base.length(sol.sol.t)]
    Base.Any[sol.sol(tf; idxs = v) for v in sol.sts]
end

# maxComponentJ sol idx : Effect Number  (idx 0-based, PS-declared order)
maxComponentJ(sol) = idx -> () -> begin
    v = sol.sts[idx + 1]
    Base.maximum(sol.sol[v])
end
