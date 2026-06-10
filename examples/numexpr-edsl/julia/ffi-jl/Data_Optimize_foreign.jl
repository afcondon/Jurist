# FFI for Data.Optimize — provably-optimal mixed-integer programming via JuMP.
#
# PureScript hands across a typed knapsack (item weights, values, capacity).
# Julia builds a 0/1 MILP with JuMP, solves it with HiGHS's branch-and-bound,
# and returns the optimal selection together with the *proof* of optimality
# (termination status OPTIMAL, relative gap 0). The JS/WASM backends have no
# equivalent — there is no MILP solver to hand a model to.
#
# Macro note: inside the generated module the sense and binary tags must not be
# written as bare special symbols (`Max`, `Bin`) — use the constant
# `JuMP.MAX_SENSE` and the `binary = true` keyword, both of which survive
# qualification (validated in a standalone module probe before this shim).

import JuMP
import HiGHS

# knapsackJ weights values cap : Effect (Array Number)
#   -> [objective, relativeGap, optimalFlag, chosen₁, …, chosenₙ]
knapsackJ(weights) = values -> cap -> () -> begin
    n = Base.length(weights)
    m = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(m)
    JuMP.@variable(m, x[1:n], binary = true)
    JuMP.@constraint(m, Base.sum(weights[i] * x[i] for i in 1:n) <= Base.Float64(cap))
    JuMP.@objective(m, JuMP.MAX_SENSE, Base.sum(values[i] * x[i] for i in 1:n))
    JuMP.optimize!(m)
    opt = JuMP.termination_status(m) == JuMP.MOI.OPTIMAL ? 1.0 : 0.0
    chosen = Base.Float64[JuMP.value(x[i]) > 0.5 ? 1.0 : 0.0 for i in 1:n]
    Base.vcat(Base.Float64[JuMP.objective_value(m), JuMP.relative_gap(m), opt], chosen)
end
