#!/usr/bin/env julia
#
# The native arm of the seam-tax lane: the SAME loop, the SAME library calls,
# written as a plain Julia program with no PureScript anywhere.
#
# Correspondence with `src/Seam/Main.purs` is the whole experiment, so it is
# maintained deliberately and narrowly:
#
#   * identical call count (400), identical (a, e) schedule, identical
#     horizons and payload sizes;
#   * identical solver configuration — Vern9, tol 1e-8, one
#     VectorContinuousCallback carrying both events;
#   * identical accumulation, so the CHECKSUMS must match. The runner diffs
#     them before it looks at a timing, because a benchmark that computes a
#     different answer quickly is the classic way for a perf lane to stay
#     green while what it measures rots.
#
# The solver body is duplicated from ffi-jl/Seam_Kernel_foreign.jl rather than
# shared. That is intentional: sharing it would make the two arms the same
# code path, and there would be nothing left to compare.
#
#   julia --project=../julia-env native/seam_native.jl

import OrdinaryDiffEq
import SciMLBase
import StaticArrays

const R_ESC_SQ = 9.0
const TOL = 1.0e-8
const MU = 9.54e-4
const CALLS = 400
const HORIZONS = [2.0, 5.0, 15.0, 50.0, 150.0]
const PAYLOADS = [1, 16, 128, 1024]
const SCHEMA = "1"

function cr3bp(u, mu, t)
    x, y, vx, vy = u
    m1 = 1.0 - mu
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1c = r1sq * sqrt(r1sq)
    r2c = r2sq * sqrt(r2sq)
    StaticArrays.SVector(vx, vy,
        x + 2.0 * vy - m1 * dx1 / r1c - mu * dx2 / r2c,
        y - 2.0 * vx - m1 * y / r1c - mu * y / r2c)
end

function init_state(mu, a, e)
    rp = a * (1.0 - e)
    x = rp - mu
    StaticArrays.SVector(x, 0.0, 0.0, sqrt((1.0 - mu) * (1.0 + e) / rp) - x)
end

function events(mu)
    rH = (mu / 3.0)^(2.0 / 3.0)
    OrdinaryDiffEq.VectorContinuousCallback(
        (out, u, t, integ) -> begin
            out[1] = (u[1] + mu)^2 + u[2]^2 - R_ESC_SQ
            out[2] = (u[1] - 1.0 + mu)^2 + u[2]^2 - rH
        end,
        (integ, idx) -> SciMLBase.terminate!(integ),
        2)
end

# Mirrors Seam.Main.paramsFor — integer arithmetic, so it costs nothing and
# both arms visit exactly the same orbits.
params_for(i) = (a = 0.35 + 0.5 * ((i * 37) % 101) / 100.0,
                 e = 0.30 * ((i * 53) % 97) / 96.0)

const FOREIGN_NS = Ref{UInt64}(0)

function solve_orbit(mu, a, e, horizon_periods)
    t0 = time_ns()
    horizon = horizon_periods * 2.0 * pi
    prob = OrdinaryDiffEq.ODEProblem(cr3bp, init_state(mu, a, e), (0.0, horizon), mu)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Vern9();
        callback = events(mu), abstol = TOL, reltol = TOL,
        save_everystep = false, save_start = false, dense = false,
        maxiters = 10_000_000)
    v = sol.t[end] >= horizon ? 1.0 : round(sol.t[end] / horizon; digits = 4)
    FOREIGN_NS[] += time_ns() - t0
    v
end

function solve_orbit_samples(mu, a, e, horizon_periods, n_samples)
    t0 = time_ns()
    horizon = horizon_periods * 2.0 * pi
    n = Int(n_samples)
    # `range(a, b; length = 1)` is an error in Julia; n = 1 is the thin
    # control. Mirrors the same guard in ffi-jl/Seam_Kernel_foreign.jl.
    ts = n == 1 ? [horizon] : range(0.0, horizon; length = n)
    prob = OrdinaryDiffEq.ODEProblem(cr3bp, init_state(mu, a, e), (0.0, horizon), mu)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Vern9();
        callback = events(mu), abstol = TOL, reltol = TOL,
        saveat = ts, maxiters = 10_000_000)
    out = Vector{Float64}(undef, 2 * n)
    m = length(sol.u)
    for i in 1:n
        u = sol.u[min(i, m)]
        out[2 * i - 1] = u[1]
        out[2 * i] = u[2]
    end
    FOREIGN_NS[] += time_ns() - t0
    out
end

const REPS = 3

emit(axis, param, first, r) =
    println("SEAM ", axis, " ", param, " ", CALLS, " ",
            first / 1000.0, " ", r.total / 1000.0, " ", r.inlib / 1000.0, " ", r.checksum)

# One first pass for the compile-dominated number, then REPS more keeping the
# fastest WHOLE pass and its own in-library time. Mirrors `timed` in
# Seam.Main; taking the two from different passes is how a split ends up
# summing to more than the whole.
function timed(body)
    r0 = body()
    best = r0
    for _ in 1:REPS
        r = body()
        r.total < best.total && (best = r)
    end
    (first = r0.total, best = best)
end

function run_work(horizon)
    res = timed() do
        FOREIGN_NS[] = 0
        acc = 0.0
        t0 = time_ns()
        for i in 0:(CALLS - 1)
            p = params_for(i)
            acc += solve_orbit(MU, p.a, p.e, horizon)
        end
        t1 = time_ns()
        (total = Float64(t1 - t0), inlib = Float64(FOREIGN_NS[]), checksum = acc)
    end
    emit("work", horizon, res.first, res.best)
    flush(stdout)
end

function run_payload(n_samples)
    res = timed() do
        FOREIGN_NS[] = 0
        acc = 0.0
        t0 = time_ns()
        for i in 0:(CALLS - 1)
            p = params_for(i)
            xs = solve_orbit_samples(MU, p.a, p.e, 15.0, n_samples)
            # Must associate EXACTLY as `Ref.modify_ (_ + Array.foldl (+) 0.0 xs)`
            # does: a per-array subtotal from 0.0, then one add into acc.
            # Neither `sum(xs)` (pairwise) nor accumulating straight into acc
            # (different association) reproduces it, and floating-point addition
            # is not associative — the checksum gate caught both attempts, at
            # 3e-9 on a 1.4e4 total.
            sub = 0.0
            for v in xs
                sub += v
            end
            acc += sub
        end
        t1 = time_ns()
        (total = Float64(t1 - t0), inlib = Float64(FOREIGN_NS[]), checksum = acc)
    end
    emit("payload", n_samples, res.first, res.best)
    flush(stdout)
end

function main()
    println("SEAM-SCHEMA ", SCHEMA)
    flush(stdout)
    for h in HORIZONS
        run_work(h)
    end
    for n in PAYLOADS
        run_payload(n)
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
