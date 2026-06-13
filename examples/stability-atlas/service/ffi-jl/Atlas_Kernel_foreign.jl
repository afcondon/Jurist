# User FFI shim for module Atlas.Kernel — the hot leaf of the stability
# atlas. The RK4 here mirrors Atlas.Dynamics.rk4Step OPERATION FOR
# OPERATION (same IEEE doubles, same association); kernelProbe exposes it
# so the PS side can verify that claim at boot against integrateSteps.
#
# Threading: rows within a block run under Threads.@threads — launch the
# service with `julia -t auto`. Each emit callback fires on the listener
# task, once per row block (coarse grain, ADR-0007).

# --- dynamics (mirror of Atlas.Dynamics; keep in lockstep) -------------------

@inline function _accel(mu::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1c = r1sq * Base.sqrt(r1sq)
    r2c = r2sq * Base.sqrt(r2sq)
    ax = x + 2.0 * vy - (1.0 - mu) * dx1 / r1c - mu * dx2 / r2c
    ay = y - 2.0 * vx - (1.0 - mu) * y / r1c - mu * y / r2c
    (ax, ay)
end

@inline function _rk4_step(mu::Float64, dt::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
    h = dt / 2.0
    a1x, a1y = _accel(mu, x, y, vx, vy)
    k2x = vx + h * a1x
    k2y = vy + h * a1y
    a2x, a2y = _accel(mu, x + h * vx, y + h * vy, k2x, k2y)
    k3x = vx + h * a2x
    k3y = vy + h * a2y
    a3x, a3y = _accel(mu, x + h * k2x, y + h * k2y, k3x, k3y)
    k4x = vx + dt * a3x
    k4y = vy + dt * a3y
    a4x, a4y = _accel(mu, x + dt * k3x, y + dt * k3y, k4x, k4y)
    ( x + dt / 6.0 * (vx + 2.0 * k2x + 2.0 * k3x + k4x)
    , y + dt / 6.0 * (vy + 2.0 * k2y + 2.0 * k3y + k4y)
    , vx + dt / 6.0 * (a1x + 2.0 * a2x + 2.0 * a3x + a4x)
    , vy + dt / 6.0 * (a1y + 2.0 * a2y + 2.0 * a3y + a4y)
    )
end

# Acceleration AND the Jacobian entries of the variational equations
# (Uxx, Uyy, Uxy of the effective potential), sharing the r¹/r³/r⁵ work.
# Tangent ODE: δẋ=δvx, δẏ=δvy, δv̇x=Uxx·δx+Uxy·δy+2δvy, δv̇y=Uxy·δx+Uyy·δy−2δvx.
@inline function _accel_jac(mu::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
    m1 = 1.0 - mu
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1 = Base.sqrt(r1sq)
    r2 = Base.sqrt(r2sq)
    r1c = r1sq * r1
    r2c = r2sq * r2
    r15 = r1c * r1sq
    r25 = r2c * r2sq
    ax = x + 2.0 * vy - m1 * dx1 / r1c - mu * dx2 / r2c
    ay = y - 2.0 * vx - m1 * y / r1c - mu * y / r2c
    uxx = 1.0 - m1 / r1c + 3.0 * m1 * dx1 * dx1 / r15 - mu / r2c + 3.0 * mu * dx2 * dx2 / r25
    uyy = 1.0 - m1 / r1c + 3.0 * m1 * y * y / r15 - mu / r2c + 3.0 * mu * y * y / r25
    uxy = 3.0 * m1 * dx1 * y / r15 + 3.0 * mu * dx2 * y / r25
    (ax, ay, uxx, uyy, uxy)
end

# One RK4 step of the combined 8-dim (state + tangent) system. Structure
# mirrors _rk4_step; tangent stages use the Jacobian at each stage's
# state. FLI-only path — plain survival keeps the oracle-verified 4-dim
# _rk4_step.
@inline function _rk4_step8(mu::Float64, dt::Float64,
        x::Float64, y::Float64, vx::Float64, vy::Float64,
        px::Float64, py::Float64, pvx::Float64, pvy::Float64)
    h = dt / 2.0
    a1x, a1y, j1xx, j1yy, j1xy = _accel_jac(mu, x, y, vx, vy)
    d1vx = j1xx * px + j1xy * py + 2.0 * pvy
    d1vy = j1xy * px + j1yy * py - 2.0 * pvx
    s2x = x + h * vx;  s2y = y + h * vy
    k2x = vx + h * a1x; k2y = vy + h * a1y
    q2x = px + h * pvx; q2y = py + h * pvy
    q2vx = pvx + h * d1vx; q2vy = pvy + h * d1vy
    a2x, a2y, j2xx, j2yy, j2xy = _accel_jac(mu, s2x, s2y, k2x, k2y)
    d2vx = j2xx * q2x + j2xy * q2y + 2.0 * q2vy
    d2vy = j2xy * q2x + j2yy * q2y - 2.0 * q2vx
    s3x = x + h * k2x; s3y = y + h * k2y
    k3x = vx + h * a2x; k3y = vy + h * a2y
    q3x = px + h * q2vx; q3y = py + h * q2vy
    q3vx = pvx + h * d2vx; q3vy = pvy + h * d2vy
    a3x, a3y, j3xx, j3yy, j3xy = _accel_jac(mu, s3x, s3y, k3x, k3y)
    d3vx = j3xx * q3x + j3xy * q3y + 2.0 * q3vy
    d3vy = j3xy * q3x + j3yy * q3y - 2.0 * q3vx
    s4x = x + dt * k3x; s4y = y + dt * k3y
    k4x = vx + dt * a3x; k4y = vy + dt * a3y
    q4x = px + dt * q3vx; q4y = py + dt * q3vy
    q4vx = pvx + dt * d3vx; q4vy = pvy + dt * d3vy
    a4x, a4y, j4xx, j4yy, j4xy = _accel_jac(mu, s4x, s4y, k4x, k4y)
    d4vx = j4xx * q4x + j4xy * q4y + 2.0 * q4vy
    d4vy = j4xy * q4x + j4yy * q4y - 2.0 * q4vx
    ( x + dt / 6.0 * (vx + 2.0 * k2x + 2.0 * k3x + k4x)
    , y + dt / 6.0 * (vy + 2.0 * k2y + 2.0 * k3y + k4y)
    , vx + dt / 6.0 * (a1x + 2.0 * a2x + 2.0 * a3x + a4x)
    , vy + dt / 6.0 * (a1y + 2.0 * a2y + 2.0 * a3y + a4y)
    , px + dt / 6.0 * (pvx + 2.0 * q2vx + 2.0 * q3vx + q4vx)
    , py + dt / 6.0 * (pvy + 2.0 * q2vy + 2.0 * q3vy + q4vy)
    , pvx + dt / 6.0 * (d1vx + 2.0 * d2vx + 2.0 * d3vx + d4vx)
    , pvy + dt / 6.0 * (d1vy + 2.0 * d2vy + 2.0 * d3vy + d4vy)
    )
end

# FLI verdict for one pixel: survived → 1 + min(FLI, 8)/8, FLI = log₁₀ of
# max tangent growth (renormalized against overflow); lost → survival
# fraction, same encoding as the plain path.
function _survival_fli(mu::Float64, a::Float64, e::Float64, horizon::Float64, stepsPerPeriod::Float64)
    rp = a * (1.0 - e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x
    px, py, pvx, pvy = 0.5, 0.5, 0.5, 0.5
    dt = 2.0 * pi * (a * Base.sqrt(a)) / stepsPerPeriod   # a*sqrt(a), not a^1.5: sqrt is exactly rounded everywhere, pow is not — mirrors Atlas.Dynamics.asteroidPeriod
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0
    t = 0.0
    accLog = 0.0
    maxLog = 0.0
    n = 0
    while t < horizon
        x, y, vx, vy, px, py, pvx, pvy = _rk4_step8(mu, dt, x, y, vx, vy, px, py, pvx, pvy)
        t += dt
        n += 1
        dx1 = x + mu
        dx2 = x - 1.0 + mu
        if dx1 * dx1 + y * y > rEscSq || (dx2 * dx2 + y * y) < rHillSq
            return Base.round(t / horizon; digits = 4)
        end
        if n % 16 == 0
            nrm = Base.sqrt(px * px + py * py + pvx * pvx + pvy * pvy)
            maxLog = Base.max(maxLog, accLog + Base.log10(nrm))
            if nrm > 1.0e12
                accLog += Base.log10(nrm)
                px /= nrm; py /= nrm; pvx /= nrm; pvy /= nrm
            end
        end
    end
    1.0 + Base.round(Base.min(maxLog, 8.0) / 8.0; digits = 4)
end

# Survival fraction of the horizon for one pixel: 1.0 = survived, else
# t_event/horizon. Events: heliocentric escape (r1 > 3) and Jupiter
# close encounter (r2 < Hill radius).
function _survival(mu::Float64, a::Float64, e::Float64, horizon::Float64, stepsPerPeriod::Float64)
    rp = a * (1.0 - e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x
    dt = 2.0 * pi * (a * Base.sqrt(a)) / stepsPerPeriod   # a*sqrt(a), not a^1.5: sqrt is exactly rounded everywhere, pow is not — mirrors Atlas.Dynamics.asteroidPeriod
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0
    t = 0.0
    while t < horizon
        x, y, vx, vy = _rk4_step(mu, dt, x, y, vx, vy)
        t += dt
        dx1 = x + mu
        dx2 = x - 1.0 + mu
        r1sq = dx1 * dx1 + y * y
        r2sq = dx2 * dx2 + y * y
        if r1sq > rEscSq || r2sq < rHillSq
            return Base.round(t / horizon; digits = 4)
        end
    end
    1.0
end

# --- foreigns ----------------------------------------------------------------

# runSweepImpl :: SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number
#
# Function barrier with @nospecialize(emit): every closure definition site
# is its own Julia TYPE, so without this the whole sweep body (threads
# machinery included) would re-JIT for each distinct callback — measured
# as ~4 s on the first real sweep even after a warmup with a different
# callback. emit fires once per row block; dynamic dispatch there is free.
runSweepImpl(spec) = emit -> () -> _run_sweep(spec, emit)

function _run_sweep(spec, @nospecialize(emit))
    t0 = Base.time_ns()
    aMin = spec["aMin"]::Float64
    aMax = spec["aMax"]::Float64
    eMin = spec["eMin"]::Float64
    eMax = spec["eMax"]::Float64
    cols = Base.Int(spec["cols"])
    rows = Base.Int(spec["rows"])
    horizon = spec["horizonPeriods"]::Float64 * 2.0 * pi
    mu = spec["mu"]::Float64
    withFli = spec["withFli"]::Bool
    stepsPerPeriod = 120.0   # mirror of Atlas.Dynamics.stepsPerPeriod

    da = cols > 1 ? (aMax - aMin) / (cols - 1) : 0.0
    de = rows > 1 ? (eMax - eMin) / (rows - 1) : 0.0
    # Blocks of 2×nthreads rows: every thread busy, few barriers, and
    # adjacent rows cost alike (cost varies smoothly with e) so @threads
    # stays balanced.
    blockRows = Base.max(2 * Threads.nthreads(), Base.cld(rows, 40))

    r0 = 1
    while r0 <= rows
        r1 = Base.min(r0 + blockRows - 1, rows)
        block = Base.Vector{Any}(undef, r1 - r0 + 1)
        Threads.@threads for r in r0:r1
            e = eMin + de * (r - 1)
            rowvals = Base.Vector{Float64}(undef, cols)
            for c in 1:cols
                a = aMin + da * (c - 1)
                rowvals[c] = withFli ?
                    _survival_fli(mu, a, e, horizon, stepsPerPeriod) :
                    _survival(mu, a, e, horizon, stepsPerPeriod)
            end
            block[r - r0 + 1] = rowvals
        end
        emit(Base.Dict{Base.String, Any}("rowStart" => r0 - 1, "rows" => block))()
        r0 = r1 + 1
    end
    return (Base.time_ns() - t0) / 1.0e6
end

# kernelProbe :: Number -> Number -> Int -> State -> State
kernelProbe(mu) = dt -> steps -> s0 -> begin
    x = s0["x"]::Float64
    y = s0["y"]::Float64
    vx = s0["vx"]::Float64
    vy = s0["vy"]::Float64
    for _ in 1:Base.Int(steps)
        x, y, vx, vy = _rk4_step(mu, dt, x, y, vx, vy)
    end
    Base.Dict{Base.String, Any}("x" => x, "y" => y, "vx" => vx, "vy" => vy)
end

# runTrajectoryImpl :: TrajSpec -> (Array Frame -> Effect Unit) -> Effect Unit
# Same @nospecialize barrier as the sweep.
runTrajectoryImpl(spec) = emit -> () -> _run_traj(spec, emit)

const _TRAJ_BLOCK = 256

function _run_traj(spec, @nospecialize(emit))
    a = spec["a"]::Float64
    e = spec["e"]::Float64
    horizon = spec["horizonPeriods"]::Float64 * 2.0 * pi
    mu = spec["mu"]::Float64
    stride = Base.max(1, Base.Int(spec["frameStride"]))
    stepsPerPeriod = 120.0   # mirror of Atlas.Dynamics.stepsPerPeriod

    rp = a * (1.0 - e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x
    dt = 2.0 * pi * (a * Base.sqrt(a)) / stepsPerPeriod   # a*sqrt(a), not a^1.5: sqrt is exactly rounded everywhere, pow is not — mirrors Atlas.Dynamics.asteroidPeriod
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0

    frame(t) = begin
        dx1 = x + mu
        dx2 = x - 1.0 + mu
        r1 = Base.sqrt(dx1 * dx1 + y * y)
        r2 = Base.sqrt(dx2 * dx2 + y * y)
        jac = x * x + y * y + 2.0 * (1.0 - mu) / r1 + 2.0 * mu / r2 - vx * vx - vy * vy
        Base.Dict{Base.String, Any}(
            "t" => t, "x" => x, "y" => y, "vx" => vx, "vy" => vy, "jacobi" => jac)
    end

    block = Any[frame(0.0)]
    t = 0.0
    alive = true
    while alive && t < horizon
        for _ in 1:stride
            x, y, vx, vy = _rk4_step(mu, dt, x, y, vx, vy)
            t += dt
            dx1 = x + mu
            dx2 = x - 1.0 + mu
            if dx1 * dx1 + y * y > rEscSq || dx2 * dx2 + y * y < rHillSq
                alive = false
                break
            end
        end
        Base.push!(block, frame(t))
        if Base.length(block) >= _TRAJ_BLOCK
            emit(block)()
            block = Any[]
        end
    end
    if !Base.isempty(block)
        emit(block)()
    end
    nothing
end
