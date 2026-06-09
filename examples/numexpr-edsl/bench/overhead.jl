# Keystone benchmark for ADR-0007: does starting a computation on the PureScript
# side of the FFI cost anything in the hot loop, versus a 100%-Julia program?
#
# The seam is crossed ONCE at staging time; after that the RHS is a native
# RuntimeGeneratedFunction and the integration loop is pure Julia. So the claim
# is: per-step cost should match hand-written Julia — the abstraction is free.
#
# We integrate the Lorenz system with one identical RK4 loop, swapping only how
# the RHS is computed, three ways:
#
#   (a) staged-naive    — N per-equation RGFs in a Vector{Any}, called via
#                         `f(args...)` with a splatted Vector. The shape the FFI
#                         emitted BEFORE this benchmark exposed its cost.
#   (b) hand-written    — the idiomatic Julia RHS a human would write inline.
#   (c) staged-fused    — a single RGF over the state/param vectors, splat-free.
#                         What ffi-jl/Data_SystemSpec_foreign.jl emits TODAY
#                         (compileFieldJ builds exactly this fused lambda).
#
# (b) is the baseline; (c) is our shipping path — it should match (b); (a) is
# kept to document why we fuse (the per-equation-Vector-splat tax).
#
# Methodology: no BenchmarkTools dependency (keeps this runnable against the
# committed julia-env with zero network). Manual harness — JIT warmup, then the
# MINIMUM over many samples (least-noise estimator, filters GC/scheduler jitter).
#
# Run: julia --project=julia-env bench/overhead.jl

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

# ── Lorenz, staged exactly as the eDSL pipeline stages it ───────────────────
# stateVars alphabetical: x,y,z ; paramVars alphabetical: beta,rho,sigma.
const PARAMS = Expr(:tuple, :x, :y, :z, :beta, :rho, :sigma)
const BODY_X = :(sigma * (y - x))
const BODY_Y = :(x * (rho - z) - y)
const BODY_Z = :(x * y - beta * z)

# (a) per-equation RGFs in a Vector{Any} — faithful to integrateJ
const FNS = Any[
    RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Expr(:->, PARAMS, BODY_X)),
    RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Expr(:->, PARAMS, BODY_Y)),
    RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Expr(:->, PARAMS, BODY_Z)),
]

# (c) one fused RGF returning the whole vector
const BODY_ALL = :(Float64[sigma * (y - x), x * (rho - z) - y, x * y - beta * z])
const FUSED = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Expr(:->, PARAMS, BODY_ALL))

# ── Three RHS closures (same signature: state, pvals -> Vector{Float64}) ─────
rhs_staged_current = (state, pvals) -> begin
    args = vcat(state, pvals)
    Float64[f(args...) for f in FNS]
end

rhs_hand = (state, pvals) -> @inbounds Float64[
    pvals[3] * (state[2] - state[1]),               # sigma*(y-x)
    state[1] * (pvals[2] - state[3]) - state[2],    # x*(rho-z)-y
    state[1] * state[2] - pvals[1] * state[3],      # x*y - beta*z
]

rhs_staged_fused = (state, pvals) ->
    @inbounds FUSED(state[1], state[2], state[3], pvals[1], pvals[2], pvals[3])

# ── One RK4 loop, structurally identical to integrateJ ──────────────────────
function rk4_solve(rhs, s0::Vector{Float64}, pvals::Vector{Float64}, dt::Float64, steps::Int)
    state = copy(s0)
    for _ in 1:steps
        k1 = rhs(state, pvals)
        k2 = rhs(state .+ (dt / 2) .* k1, pvals)
        k3 = rhs(state .+ (dt / 2) .* k2, pvals)
        k4 = rhs(state .+ dt .* k3, pvals)
        state = state .+ (dt / 6) .* (k1 .+ 2 .* k2 .+ 2 .* k3 .+ k4)
    end
    state
end

# ── Manual benchmark: warmup, then minimum over samples ─────────────────────
function bench(f; warmups = 5, samples = 80)
    for _ in 1:warmups
        f()
    end
    best = Inf
    for _ in 1:samples
        t = @elapsed f()
        best = min(best, t)
    end
    best
end

const S0 = [1.0, 1.0, 1.0]
const PVALS = [8.0 / 3.0, 28.0, 10.0]   # beta, rho, sigma
const DT = 0.01
const STEPS = 5000

# Correctness: all three must integrate to the same final state (equal work).
function assert_same()
    a = rk4_solve(rhs_staged_current, S0, PVALS, DT, STEPS)
    b = rk4_solve(rhs_hand, S0, PVALS, DT, STEPS)
    c = rk4_solve(rhs_staged_fused, S0, PVALS, DT, STEPS)
    ok = isapprox(a, b; rtol = 1e-12) && isapprox(a, c; rtol = 1e-12)
    println("correctness: all three RHS agree to 1e-12: ", ok, "   (final z = ", round(a[3], digits = 6), ")")
    ok
end

function report(label, t)
    per_step = t / STEPS * 1e9   # ns per step (4 RHS evals + RK4 combine)
    println(rpad(label, 22), lpad(round(t * 1e6, digits = 2), 10), " µs/solve   ",
        lpad(round(per_step, digits = 1), 8), " ns/step")
end

# ── One-time staging cost (build RGFs + first-call compilation) ─────────────
function staging_cost()
    t = @elapsed begin
        f1 = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(Expr(:->, PARAMS, BODY_X))
        f1(1.0, 1.0, 1.0, 1.0, 1.0, 1.0)   # force compilation
    end
    t
end

function main()
    println("== ADR-0007 overhead benchmark: staged PureScript vs hand-written Julia ==")
    println("Lorenz, ", STEPS, " RK4 steps, dt=", DT, "  (min over 80 samples after warmup)\n")
    assert_same()
    println()

    tc = bench(() -> rk4_solve(rhs_staged_current, S0, PVALS, DT, STEPS))
    th = bench(() -> rk4_solve(rhs_hand, S0, PVALS, DT, STEPS))
    tf = bench(() -> rk4_solve(rhs_staged_fused, S0, PVALS, DT, STEPS))

    report("(b) hand-written", th)
    report("(c) staged-fused", tf)
    report("(a) staged-naive", tc)
    println()
    println("staged-fused / hand    : ", round(tf / th, digits = 3), "×  (the SHIPPING path — ≈1.0 ⟹ the abstraction is free)")
    println("staged-naive / hand    : ", round(tc / th, digits = 3), "×  (the per-eq Vector-splat shape we fused away)")
    println()
    println("one-time staging cost  : ", round(staging_cost() * 1e3, digits = 3), " ms (build RGF + first-call compile; amortised over the whole solve)")
end

main()
