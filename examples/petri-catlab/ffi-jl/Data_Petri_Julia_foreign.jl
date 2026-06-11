# FFI for Data.Petri.Julia — Tier-3, AlgebraicJulia.
#
# PureScript hands across a Petri net as plain arrays (species; per-transition
# input/output species; initial concentrations; rates). Julia assembles an
# AlgebraicPetri LabelledPetriNet, applies the *functorial* mass-action semantics
# (`AP.vectorfield`) to get the ODE vector field — the dynamics is a functor from
# the Petri category, not a hand translation — and OrdinaryDiffEq solves it.
#
# Qualified library calls throughout — this file is `include`d inside the
# generated `Data_Petri_Julia` module.
#
# Gotcha (validated in a probe first): AlgebraicPetri's transition parser wants a
# *bare Symbol* for a single input/output species and a *Tuple* for several; a
# 1-tuple `(:I,)` is rejected. `_tup` handles that.

import AlgebraicPetri
import OrdinaryDiffEq
import LabelledArrays

_tup(xs) = Base.length(xs) == 1 ? Base.Symbol(xs[1]) : Tuple(Base.Symbol(s) for s in xs)

function _build(species, tnames, inputs, outputs)
    sp = [Base.Symbol(s) for s in species]
    trans = [Base.Symbol(tnames[i]) => (_tup(inputs[i]) => _tup(outputs[i])) for i in 1:Base.length(tnames)]
    AlgebraicPetri.LabelledPetriNet(sp, trans...)
end

# solveJ species tnames inputs outputs initial rates t0 t1 n : Effect (Array (Array Number))
#   -> [[t, conc₁, …, concₖ], …]  (n+1 evenly-spaced samples, species order)
solveJ(species) = tnames -> inputs -> outputs -> initial -> rates -> t0 -> t1 -> n -> () -> begin
    pn = _build(species, tnames, inputs, outputs)
    sp = [Base.Symbol(s) for s in species]
    u0 = LabelledArrays.LVector(; (sp[i] => Base.Float64(initial[i]) for i in 1:Base.length(sp))...)
    rt = LabelledArrays.LVector(; (Base.Symbol(tnames[i]) => Base.Float64(rates[i]) for i in 1:Base.length(tnames))...)
    a = Base.Float64(t0)
    b = Base.Float64(t1)
    prob = OrdinaryDiffEq.ODEProblem(AlgebraicPetri.vectorfield(pn), u0, (a, b), rt)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Tsit5())
    out = Base.Any[]
    for k in 0:n
        t = a + (b - a) * k / n
        u = sol(t)
        row = Base.Any[t]
        for i in 1:Base.length(sp)
            Base.push!(row, Base.Float64(u[i]))
        end
        Base.push!(out, row)
    end
    out
end

# Mass-action flux of a transition as LaTeX: rate · ∏ inputᵢ^multiplicity.
function _flux_latex(tname, inputs_i)
    counts = Base.Dict{Base.String, Base.Int}()
    for s in inputs_i
        counts[s] = Base.get(counts, s, 0) + 1
    end
    parts = Base.String["\\mathrm{" * tname * "}"]
    for s in Base.sort(Base.collect(Base.keys(counts)))
        c = counts[s]
        Base.push!(parts, c == 1 ? s : s * "^{" * Base.string(c) * "}")
    end
    Base.join(parts, " \\, ")
end

# odeLawsJ species tnames inputs outputs : Effect (Array String)
#   -> one LaTeX mass-action ODE per species, derived from the net stoichiometry.
odeLawsJ(species) = tnames -> inputs -> outputs -> () -> begin
    laws = Base.String[]
    for s in species
        terms = Base.String[]
        for i in 1:Base.length(tnames)
            net = Base.count(Base.isequal(s), outputs[i]) - Base.count(Base.isequal(s), inputs[i])
            if net != 0
                coef = Base.abs(net) == 1 ? "" : Base.string(Base.abs(net)) * " "
                sgn = net > 0 ? "+ " : "- "
                Base.push!(terms, sgn * coef * _flux_latex(tnames[i], inputs[i]))
            end
        end
        body = Base.isempty(terms) ? "0" : Base.join(terms, " ")
        body = Base.replace(body, r"^\+ " => "")
        Base.push!(laws, "\\frac{d" * s * "}{dt} = " * body)
    end
    laws
end

# writeTextJ path content : Effect Unit
writeTextJ(path) = content -> () -> begin
    Base.open(path, "w") do io
        Base.write(io, content)
    end
    Base.nothing
end
