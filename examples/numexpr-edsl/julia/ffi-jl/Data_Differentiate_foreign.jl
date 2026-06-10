# FFI for Data.Differentiate — the differentiation round-trip.
#
# PureScript hands across the ordered variable names plus one `JExpr` per
# expression (a Julia Expr over bare Symbols, folded through the Data.NumExpr
# builders — ADR-0002, the shim never destructures a PS ADT). Here Julia binds
# those names to *scalar* Symbolics variables (cf. Data.MTKSystem, which binds
# them as functions of t), denotes the Expr into a symbolic term, differentiates
# it with Symbolics, and renders the derivative as LaTeX via Latexify.
#
# Every library call is qualified — this file is `include`d inside the generated
# `Data_Differentiate` module, where PureScript-defined names could otherwise
# shadow the library functions.

import Symbolics
import Latexify

# Declare scalar symbolic vars in the given order, bind the JExpr's bare Symbols
# to them in a `let`, and eval so `+`/`*`/sin/… build a symbolic term.
function _jurist_denote_scalar(vars, jexpr)
    syms = Base.Any[Symbolics.variable(Base.Symbol(v)) for v in vars]
    assigns = Base.Any[Base.Expr(:(=), Base.Symbol(vars[i]), syms[i]) for i in Base.eachindex(vars)]
    letblk = Base.Expr(:let, Base.Expr(:block, assigns...), jexpr)
    (Base.eval(@__MODULE__, letblk), syms)
end

# Greek-letter variable names (sigma, rho, …) come out of Latexify as
# `\mathtt{sigma}`; map them to the actual Greek control sequences so the typeset
# math reads the way a mathematician wrote it.
const _JURIST_GREEK = ["alpha","beta","gamma","delta","epsilon","zeta","eta",
    "theta","iota","kappa","lambda","mu","nu","xi","pi","rho","sigma","tau",
    "phi","chi","psi","omega"]

# Latexify wraps output in an equation environment; KaTeX wants just the body.
function _jurist_strip_latex(s)
    t = Base.String(s)
    t = Base.replace(t, "\\begin{equation}" => "")
    t = Base.replace(t, "\\end{equation}" => "")
    for g in _JURIST_GREEK
        t = Base.replace(t, "\\mathtt{" * g * "}" => "\\" * g)
    end
    Base.strip(t)
end

# exprLatexJ vars jexpr : Effect String
exprLatexJ(vars) = jexpr -> () -> begin
    (e, _) = _jurist_denote_scalar(vars, jexpr)
    _jurist_strip_latex(Latexify.latexify(e))
end

# gradientLatexJ declare wrt jexpr : Effect (Array String)
# `declare` lists every variable in the expression (so the Symbols resolve);
# `wrt` the subset to differentiate by. One ∂f/∂vᵢ per `wrt` variable — the chain
# rule done symbolically and typeset, never hand-derived in PureScript.
gradientLatexJ(declare) = wrt -> jexpr -> () -> begin
    (e, syms) = _jurist_denote_scalar(declare, jexpr)
    byname = Base.Dict(declare[i] => syms[i] for i in Base.eachindex(declare))
    Base.String[
        _jurist_strip_latex(Latexify.latexify(
            Symbolics.expand_derivatives(Symbolics.Differential(byname[w])(e))))
        for w in wrt
    ]
end

# writeTextJ path content : Effect Unit
writeTextJ(path) = content -> () -> begin
    Base.open(path, "w") do io
        Base.write(io, content)
    end
    Base.nothing
end
