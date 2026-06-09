# FFI for Data.NumExpr — Tier-2 staging (increment 1).
#
# The PS side folds its NumExpr AST through these builders (ADR-0002:
# constructors handed in, the shim never destructures a PS ADT). Each builder
# assembles a Julia `Expr` node; the whole expression is then compiled to a
# native function by `eval`-ing a generated lambda — Julia metaprogramming
# turning a description into specialized native code, the Tier-2 thesis.
#
#   JExpr handle    == a Julia Expr (or a leaf: Float64 literal / Symbol)
#   Compiled handle == the eval'd native anonymous function
#   Effect a        == a zero-arg thunk

jLit(x) = x
jVar(s) = Base.Symbol(s)
jAdd(a) = b -> Base.Expr(:call, :+, a, b)
jSub(a) = b -> Base.Expr(:call, :-, a, b)
jMul(a) = b -> Base.Expr(:call, :*, a, b)
jDiv(a) = b -> Base.Expr(:call, :/, a, b)
jNeg(a) = Base.Expr(:call, :-, a)
jPow(a) = b -> Base.Expr(:call, :^, a, b)
jApp(name) = a -> Base.Expr(:call, Base.Symbol(name), a)

# compileJ vars jexpr : Effect Compiled
# Generate  (v1, v2, …) -> <jexpr>  and eval it into a native function.
compileJ(vars) = jexpr -> () -> begin
    params = Base.Expr(:tuple, [Base.Symbol(v) for v in vars]...)
    Base.eval(@__MODULE__, Base.Expr(:->, params, jexpr))
end

# evalBatch f pts : Effect (Array Number)
# invokelatest crosses the world-age boundary created by the eval above; the
# expression body itself is native. (Production would use
# RuntimeGeneratedFunctions to drop even this per-call boundary — see ADR-0007.)
evalBatch(f) = pts -> () -> Any[Base.invokelatest(f, p...) for p in pts]
