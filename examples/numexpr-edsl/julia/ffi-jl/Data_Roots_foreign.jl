# FFI for Data.Roots — rigorous (validated) root finding.
#
# PureScript hands across a single-variable `JExpr` (a Julia Expr over a bare
# Symbol, folded through the Data.NumExpr builders — ADR-0002). We compile it to
# a native single-argument RuntimeGeneratedFunction and feed it to
# IntervalRootFinding, whose Newton contractor evaluates f (and, via ForwardDiff,
# f′) over *intervals* — IntervalArithmetic overloads +,-,*,/,sin,… on intervals,
# so the same RGF that runs on Float64 also runs rigorously on a box. The result
# is a set of proven root enclosures, each tagged :unique or :unknown.
#
# Qualified library calls throughout — this file is `include`d inside the
# generated `Data_Roots` module.

import IntervalArithmetic
import IntervalRootFinding
import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

# Build  x -> <jexpr>  as a native RGF: bind the variable name to the argument in
# a `let`, so the bare Symbol in the Expr resolves. Works on Float64 and Interval.
function _jurist_fn1(varname, jexpr)
    body = Base.Expr(:let, Base.Expr(:block, Base.Expr(:(=), Base.Symbol(varname), :x)), jexpr)
    lambda = Base.Expr(:->, :x, body)
    RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(lambda)
end

# provenRootsJ var lo hi jexpr : Effect (Array (Array Number))  -- [[lo,hi,unique],…]
provenRootsJ(varname) = lo -> hi -> jexpr -> () -> begin
    f = _jurist_fn1(varname, jexpr)
    rts = IntervalRootFinding.roots(f, IntervalArithmetic.interval(Base.Float64(lo), Base.Float64(hi)))
    out = Base.Any[]
    for r in rts
        reg = IntervalRootFinding.root_region(r)
        u = IntervalRootFinding.root_status(r) == :unique ? 1.0 : 0.0
        Base.push!(out, Base.Any[IntervalArithmetic.inf(reg), IntervalArithmetic.sup(reg), u])
    end
    out
end

# sampleCurveJ var lo hi n jexpr : Effect (Array (Array Number))  -- [[x, f(x)],…]
sampleCurveJ(varname) = lo -> hi -> n -> jexpr -> () -> begin
    f = _jurist_fn1(varname, jexpr)
    a = Base.Float64(lo)
    b = Base.Float64(hi)
    out = Base.Any[]
    for i in 0:n
        x = a + (b - a) * i / n
        Base.push!(out, Base.Any[x, Base.Float64(f(x))])
    end
    out
end
