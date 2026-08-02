# The foreign side of the seam-tax lane.
#
# Rule for this file: it contains a LIBRARY CALL and the marshalling around
# it, and nothing else. No loop, no grid, no algorithm — those live in
# PureScript, which is the whole point of the measurement. If the sweep loop
# migrated in here the numbers would flatter us and would be measuring a
# different architecture.
#
# The `_FOREIGN_NS` accumulator is what makes structural distortion
# computable: it charges only the time inside `solve`, so total-minus-foreign
# is the crossing plus the PureScript loop.

import OrdinaryDiffEq
import SciMLBase
import StaticArrays

const R_ESC_SQ = 9.0
const TOL = 1.0e-8            # matches examples/stability-atlas/native

# --- the vector field (identical to the native arm) --------------------------

function _cr3bp(u, mu, t)
    x, y, vx, vy = u
    m1 = 1.0 - mu
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1c = r1sq * Base.sqrt(r1sq)
    r2c = r2sq * Base.sqrt(r2sq)
    StaticArrays.SVector(vx, vy,
        x + 2.0 * vy - m1 * dx1 / r1c - mu * dx2 / r2c,
        y - 2.0 * vx - m1 * y / r1c - mu * y / r2c)
end

function _init(mu, a, e)
    rp = a * (1.0 - e)
    x = rp - mu
    StaticArrays.SVector(x, 0.0, 0.0, Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x)
end

function _events(mu)
    rH = (mu / 3.0)^(2.0 / 3.0)
    OrdinaryDiffEq.VectorContinuousCallback(
        (out, u, t, integ) -> begin
            out[1] = (u[1] + mu)^2 + u[2]^2 - R_ESC_SQ
            out[2] = (u[1] - 1.0 + mu)^2 + u[2]^2 - rH
        end,
        (integ, idx) -> SciMLBase.terminate!(integ),
        2)
end

# --- instrumentation ---------------------------------------------------------

const _FOREIGN_NS = Base.Ref{Base.UInt64}(0)

foreignNs = () -> Base.Float64(_FOREIGN_NS[])
resetForeignNs = () -> (_FOREIGN_NS[] = 0; nothing)

# --- the clock ---------------------------------------------------------------

nowNs = () -> Base.Float64(Base.time_ns())

flushOut = () -> (Base.flush(Base.stdout); nothing)

# --- the seam ----------------------------------------------------------------

# callLibrary :: Number -> Number -> Number -> Number -> Number
# The shared PureScript names the arguments as three shape dials and a work
# dial; here they are (mu, a, e, horizonPeriods) because the library this
# backend binds is an ODE solver.
# Curried: PureScript applies one argument at a time.
callLibrary(mu) = a -> e -> horizonPeriods -> begin
    t0 = Base.time_ns()
    horizon = horizonPeriods * 2.0 * pi
    prob = OrdinaryDiffEq.ODEProblem(_cr3bp, _init(mu, a, e), (0.0, horizon), mu)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Vern9();
        callback = _events(mu), abstol = TOL, reltol = TOL,
        save_everystep = false, save_start = false, dense = false,
        maxiters = 10_000_000)
    v = sol.t[end] >= horizon ? 1.0 : Base.round(sol.t[end] / horizon; digits = 4)
    _FOREIGN_NS[] += Base.time_ns() - t0
    v
end

# callLibraryPayload :: Number -> Number -> Number -> Number -> Int -> Array Number
# Same solve, but `nSamples` trajectory points come back instead of one
# verdict — so the difference against callLibrary at equal horizon is
# marshalling per element, with call count and library work held fixed.
callLibraryPayload(mu) = a -> e -> horizonPeriods -> nSamples -> begin
    t0 = Base.time_ns()
    horizon = horizonPeriods * 2.0 * pi
    n = Base.Int(nSamples)
    # `range(a, b; length = 1)` is an error in Julia, and n = 1 is the thin
    # control the whole payload axis is measured against, so it cannot be
    # dropped.
    ts = n == 1 ? [horizon] : Base.range(0.0, horizon; length = n)
    prob = OrdinaryDiffEq.ODEProblem(_cr3bp, _init(mu, a, e), (0.0, horizon), mu)
    sol = OrdinaryDiffEq.solve(prob, OrdinaryDiffEq.Vern9();
        callback = _events(mu), abstol = TOL, reltol = TOL,
        saveat = ts, maxiters = 10_000_000)
    # Flat [x0,y0,x1,y1,...]: a flat Array Number is the shape every backend
    # marshals the same way, so the number is comparable across runtimes.
    out = Base.Vector{Float64}(undef, 2 * n)
    m = Base.length(sol.u)
    for i in 1:n
        u = sol.u[Base.min(i, m)]
        out[2 * i - 1] = u[1]
        out[2 * i] = u[2]
    end
    _FOREIGN_NS[] += Base.time_ns() - t0
    out
end

# --- the calibrated ladders --------------------------------------------------
#
# The axis under test is MICROSECONDS of library work bought per crossing; the
# horizon is only the dial that moves it. Each backend calibrates its own
# ladder to span the same microsecond range, so the shared PureScript stays
# byte-identical (see Seam.Kernel.workLadder).
#
# Measured 2026-08-02: these settings buy 172 / 385 / 1086 / 3476 / 10139 us
# per call through OrdinaryDiffEq — a 60x range.
workLadder = [2.0, 5.0, 15.0, 50.0, 150.0]

# ~1086 us per call: the middle of the ladder, so the payload axis varies
# payload against a representative amount of work rather than an extreme.
payloadWork = 15.0
