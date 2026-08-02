#!/usr/bin/env julia
#
# NATIVE REFERENCE (b) — the stability atlas as a Julia scientist would write
# it: OrdinaryDiffEq.jl, an adaptive high-order integrator, and root-found
# event detection.
#
# This is NOT a like-for-like performance comparison, and it is not meant to
# be. Reference (a) holds the arithmetic fixed to price the harness. This one
# changes the arithmetic on purpose, to answer the two questions (a) cannot:
#
#   1. What does the ecosystem buy?  Vern9 at a set tolerance instead of RK4
#      at a fixed 120 steps/period; escape and close-encounter times located
#      by root-finding to solver tolerance instead of to the step that
#      overshot them.
#   2. Is the atlas RIGHT?  The exhibit's honesty meter proves the browser and
#      Julia agree with EACH OTHER to the last bit. That is a claim about
#      reproducibility, and it says nothing about accuracy. This reference is
#      the first thing in the exhibit capable of DISAGREEING with it.
#
# It is written to be fair to Julia rather than to flatter the incumbent — the
# configuration below was picked by measurement (see `native/RESULTS.md`), not
# by first guess:
#
#   * out-of-place `SVector` right-hand side, the idiomatic formulation for a
#     small system — a heap-allocated `Vector` state measured the same here,
#     so allocation is NOT what the ratio is measuring;
#   * ONE `VectorContinuousCallback` carrying both event functions rather than
#     a `CallbackSet` of two, which measured 11.81 ms -> 8.92 ms per survivor;
#   * `Vern9` after comparing Vern7 and Tsit5 at three tolerances each.
#
# The verdict encoding is identical to the fixed-step kernel's, so the grids
# are directly comparable pixel by pixel:
#   v in [0,1)  lost at survival fraction v of the horizon
#   v in [1,2]  survived; with FLI, (v-1)*8 is the indicator, capped at 8
#
#   julia --project=. -t auto atlas_ecosystem.jl            # :3213, tol 1e-8
#   ATLAS_ECO_TOL=1e-10 julia --project=. -t auto atlas_ecosystem.jl
#
# Serves the same protocol as the other two, so `compare.jl` drives all three
# identically and the atlas frontend can be pointed at any of them.

using HTTP
using JSON3
using OrdinaryDiffEq
using DiffEqCallbacks
using SciMLBase
using StaticArrays

const DEFAULT_PORT = 3213
const R_ESC_SQ = 9.0

# Solver tolerance. 1e-8 is well inside the fixed-step kernel's own error
# (measured ~1.3e-4 to 2.5e-4 relative on event times against a Vern9 @1e-13
# reference), so a disagreement between the two grids is attributable to the
# fixed-step kernel and not to this one.
const TOL = haskey(ENV, "ATLAS_ECO_TOL") ? parse(Float64, ENV["ATLAS_ECO_TOL"]) : 1.0e-8

# --- the dynamics ------------------------------------------------------------
#
# The same CR3BP as Atlas.Dynamics, stated as a vector field rather than as a
# stepper. The solver owns the discretisation — which is the point.

function cr3bp(u, mu, t)
    x, y, vx, vy = u
    m1 = 1.0 - mu
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1c = r1sq * sqrt(r1sq)
    r2c = r2sq * sqrt(r2sq)
    SVector(vx, vy,
        x + 2.0 * vy - m1 * dx1 / r1c - mu * dx2 / r2c,
        y - 2.0 * vx - m1 * y / r1c - mu * y / r2c)
end

# State + tangent vector, for the FLI layer. The Jacobian entries are the
# second derivatives of the effective potential; the tangent equation is
# linear in the tangent vector.
function cr3bp_var(u, mu, t)
    x, y, vx, vy, px, py, pvx, pvy = u
    m1 = 1.0 - mu
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1 = sqrt(r1sq); r2 = sqrt(r2sq)
    r1c = r1sq * r1; r2c = r2sq * r2
    r15 = r1c * r1sq; r25 = r2c * r2sq
    uxx = 1.0 - m1 / r1c + 3.0 * m1 * dx1 * dx1 / r15 - mu / r2c + 3.0 * mu * dx2 * dx2 / r25
    uyy = 1.0 - m1 / r1c + 3.0 * m1 * y * y / r15 - mu / r2c + 3.0 * mu * y * y / r25
    uxy = 3.0 * m1 * dx1 * y / r15 + 3.0 * mu * dx2 * y / r25
    SVector(vx, vy,
        x + 2.0 * vy - m1 * dx1 / r1c - mu * dx2 / r2c,
        y - 2.0 * vx - m1 * y / r1c - mu * y / r2c,
        pvx, pvy,
        uxx * px + uxy * py + 2.0 * pvy,
        uxy * px + uyy * py - 2.0 * pvx)
end

init_state(mu, a, e) = begin
    rp = a * (1.0 - e)
    x = rp - mu
    SVector(x, 0.0, 0.0, sqrt((1.0 - mu) * (1.0 + e) / rp) - x)
end

hill_sq(mu) = (mu / 3.0)^(2.0 / 3.0)

# Both events in ONE vector callback: the solver evaluates the pair together
# and root-finds only the crossing that fires. Two separate ContinuousCallbacks
# express exactly the same thing and measured ~30 % slower.
function stop_events(mu)
    rH = hill_sq(mu)
    VectorContinuousCallback(
        (out, u, t, integ) -> begin
            out[1] = (u[1] + mu)^2 + u[2]^2 - R_ESC_SQ
            out[2] = (u[1] - 1.0 + mu)^2 + u[2]^2 - rH
        end,
        (integ, idx) -> SciMLBase.terminate!(integ),
        2)
end

# --- per-pixel verdicts ------------------------------------------------------

function survival_eco(mu, a, e, horizon)
    prob = ODEProblem(cr3bp, init_state(mu, a, e), (0.0, horizon), mu)
    sol = solve(prob, Vern9();
        callback = stop_events(mu), abstol = TOL, reltol = TOL,
        save_everystep = false, save_start = false, dense = false,
        maxiters = 10_000_000)
    sol.t[end] >= horizon ? 1.0 : round(sol.t[end] / horizon; digits = 4)
end

# FLI with an adaptive solver: renormalise the tangent vector on a fixed TIME
# cadence rather than every N steps, since "N steps" has no fixed meaning once
# the stepper adapts. The cadence matches the fixed-step kernel's every-16-
# steps in time, so the two indicators are on the same scale.
function survival_fli_eco(mu, a, e, horizon)
    s0 = init_state(mu, a, e)
    u0 = SVector(s0[1], s0[2], s0[3], s0[4], 0.5, 0.5, 0.5, 0.5)
    accLog = Ref(0.0)
    maxLog = Ref(0.0)
    cadence = 16.0 * 2.0 * pi * (a * sqrt(a)) / 120.0

    renorm = PeriodicCallback(cadence; initial_affect = false) do integ
        u = integ.u
        nrm = sqrt(u[5]^2 + u[6]^2 + u[7]^2 + u[8]^2)
        maxLog[] = max(maxLog[], accLog[] + log10(nrm))
        if nrm > 1.0e12
            accLog[] += log10(nrm)
            integ.u = SVector(u[1], u[2], u[3], u[4],
                u[5] / nrm, u[6] / nrm, u[7] / nrm, u[8] / nrm)
        end
    end

    prob = ODEProblem(cr3bp_var, u0, (0.0, horizon), mu)
    sol = solve(prob, Vern9();
        callback = CallbackSet(renorm, stop_events(mu)),
        abstol = TOL, reltol = TOL,
        save_everystep = false, save_start = false, dense = false,
        maxiters = 10_000_000)
    sol.t[end] >= horizon ?
        1.0 + round(min(maxLog[], 8.0) / 8.0; digits = 4) :
        round(sol.t[end] / horizon; digits = 4)
end

# --- protocol (same shape as atlas_native.jl) --------------------------------

struct SweepSpec
    aMin::Float64; aMax::Float64; eMin::Float64; eMax::Float64
    cols::Int; rows::Int; horizonPeriods::Float64; mu::Float64; withFli::Bool
end

sweep_spec(o) = SweepSpec(
    Float64(o.aMin), Float64(o.aMax), Float64(o.eMin), Float64(o.eMax),
    Int(o.cols), Int(o.rows), Float64(o.horizonPeriods), Float64(o.mu), Bool(o.withFli))

const SWEEP_PERF = Dict{String, Float64}("kernel" => 0.0, "emit" => 0.0, "total" => 0.0)

function run_sweep(spec::SweepSpec, emit)
    t0 = time_ns()
    horizon = spec.horizonPeriods * 2.0 * pi
    da = spec.cols > 1 ? (spec.aMax - spec.aMin) / (spec.cols - 1) : 0.0
    de = spec.rows > 1 ? (spec.eMax - spec.eMin) / (spec.rows - 1) : 0.0
    blockRows = max(2 * Threads.nthreads(), cld(spec.rows, 40))

    emit_ns = UInt64(0)
    r0 = 1
    while r0 <= spec.rows
        r1 = min(r0 + blockRows - 1, spec.rows)
        block = Vector{Vector{Float64}}(undef, r1 - r0 + 1)
        Threads.@threads for r in r0:r1
            e = spec.eMin + de * (r - 1)
            rowvals = Vector{Float64}(undef, spec.cols)
            for c in 1:spec.cols
                a = spec.aMin + da * (c - 1)
                rowvals[c] = spec.withFli ?
                    survival_fli_eco(spec.mu, a, e, horizon) :
                    survival_eco(spec.mu, a, e, horizon)
            end
            block[r - r0 + 1] = rowvals
        end
        e0 = time_ns()
        emit(r0 - 1, block)
        emit_ns += time_ns() - e0
        r0 = r1 + 1
    end

    total = (time_ns() - t0) / 1.0e6
    SWEEP_PERF["emit"] = emit_ns / 1.0e6
    SWEEP_PERF["kernel"] = total - SWEEP_PERF["emit"]
    SWEEP_PERF["total"] = total
    println(stderr, "sweep-perf cols=", spec.cols, " rows=", spec.rows,
        " fli=", spec.withFli, " tol=", TOL,
        " total_ms=", total,
        " kernel_ms=", SWEEP_PERF["kernel"],
        " emit_ms=", SWEEP_PERF["emit"])
    flush(stderr)
    total
end

function handle(send, raw::String)
    msg = try
        JSON3.read(raw)
    catch err
        send(JSON3.write((tag = "ProtocolError", message = "malformed ClientMsg: $err")))
        return
    end
    tag = get(msg, :tag, nothing)
    if tag == "RequestSweep"
        elapsedMs = run_sweep(sweep_spec(msg), (rowStart, rows) ->
            send(JSON3.write((tag = "SweepRows", rowStart = rowStart, rows = rows))))
        send(JSON3.write((tag = "SweepDone", elapsedMs = elapsedMs)))
    else
        send(JSON3.write((tag = "ProtocolError",
            message = "atlas-ecosystem serves RequestSweep only; got $tag")))
    end
end

function warmup()
    for fli in (false, true)
        run_sweep(SweepSpec(0.4, 0.6, 0.0, 0.1, 8, 4, 2.0, 9.54e-4, fli),
            (rowStart, rows) -> JSON3.write((tag = "SweepRows", rowStart = rowStart, rows = rows)))
    end
    nothing
end

function main()
    port = haskey(ENV, "ATLAS_ECO_PORT") ? parse(Int, ENV["ATLAS_ECO_PORT"]) : DEFAULT_PORT
    warmup()
    println("atlas-ecosystem: listening on ws://0.0.0.0:$port (Vern9, tol $TOL)")
    flush(stdout)
    HTTP.WebSockets.listen("0.0.0.0", port) do ws
        send = str -> HTTP.WebSockets.send(ws, str)
        for msg in ws
            handle(send, String(msg))
        end
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
