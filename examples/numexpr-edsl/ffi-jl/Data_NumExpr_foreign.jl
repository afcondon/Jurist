# FFI for Data.NumExpr — Tier-2 staging (increment 1).
#
# The PS side folds its NumExpr AST through these builders (ADR-0002:
# constructors handed in, the shim never destructures a PS ADT). Each builder
# assembles a Julia `Expr` node; the whole expression is then compiled to a
# native function via RuntimeGeneratedFunctions — Julia metaprogramming turning
# a description into specialized native code, the Tier-2 thesis.
#
#   JExpr handle    == a Julia Expr (or a leaf: Float64 literal / Symbol)
#   Compiled handle == a RuntimeGeneratedFunction (native, specializing)
#   Effect a        == a zero-arg thunk

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

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
# Generate  (v1, v2, …) -> <jexpr>  as a RuntimeGeneratedFunction: native and
# specializing, with no world-age boundary (unlike `eval` of a lambda, which
# would need `invokelatest` at every call site — ADR-0007).
compileJ(vars) = jexpr -> () -> begin
    params = Base.Expr(:tuple, [Base.Symbol(v) for v in vars]...)
    lambda = Base.Expr(:->, params, jexpr)
    RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(lambda)
end

# evalBatch f pts : Effect (Array Number)
# Direct native calls — no `invokelatest`, because an RGF is callable in the
# current world age and specializes on its argument types.
evalBatch(f) = pts -> () -> Base.Any[f(p...) for p in pts]
