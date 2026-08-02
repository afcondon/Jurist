"""
The fixed-step CR3BP kernel, as a Julia programmer would keep it.

**This is a deliberate verbatim copy** of the numerics in
`service/ffi-jl/Atlas_Kernel_foreign.jl`, and that is the point: the native
reference must differ from the polyglot service in its *harness* — protocol,
serialization, socket — and nowhere else. Holding the arithmetic fixed is what
makes `poly_kernel / native_kernel ≈ 1.0` a control on the measurement rather
than a coincidence, exactly as `structural distortion` is in Grid Explorer.

So do not "improve" anything here. If the shim changes, copy it again.

The independent implementation — the one that could disagree — is
`atlas_ecosystem.jl`, which solves the same problem with OrdinaryDiffEq.jl and
event callbacks instead.
"""
module KernelFixed

export accel, rk4_step, survival, survival_fli, STEPS_PER_PERIOD

# mirror of Atlas.Dynamics.stepsPerPeriod
const STEPS_PER_PERIOD = 120.0

@inline function accel(mu::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
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

@inline function rk4_step(mu::Float64, dt::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
    h = dt / 2.0
    a1x, a1y = accel(mu, x, y, vx, vy)
    k2x = vx + h * a1x
    k2y = vy + h * a1y
    a2x, a2y = accel(mu, x + h * vx, y + h * vy, k2x, k2y)
    k3x = vx + h * a2x
    k3y = vy + h * a2y
    a3x, a3y = accel(mu, x + h * k2x, y + h * k2y, k3x, k3y)
    k4x = vx + dt * a3x
    k4y = vy + dt * a3y
    a4x, a4y = accel(mu, x + dt * k3x, y + dt * k3y, k4x, k4y)
    ( x + dt / 6.0 * (vx + 2.0 * k2x + 2.0 * k3x + k4x)
    , y + dt / 6.0 * (vy + 2.0 * k2y + 2.0 * k3y + k4y)
    , vx + dt / 6.0 * (a1x + 2.0 * a2x + 2.0 * a3x + a4x)
    , vy + dt / 6.0 * (a1y + 2.0 * a2y + 2.0 * a3y + a4y)
    )
end

@inline function accel_jac(mu::Float64, x::Float64, y::Float64, vx::Float64, vy::Float64)
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

@inline function rk4_step8(mu::Float64, dt::Float64,
        x::Float64, y::Float64, vx::Float64, vy::Float64,
        px::Float64, py::Float64, pvx::Float64, pvy::Float64)
    h = dt / 2.0
    a1x, a1y, j1xx, j1yy, j1xy = accel_jac(mu, x, y, vx, vy)
    d1vx = j1xx * px + j1xy * py + 2.0 * pvy
    d1vy = j1xy * px + j1yy * py - 2.0 * pvx
    s2x = x + h * vx;  s2y = y + h * vy
    k2x = vx + h * a1x; k2y = vy + h * a1y
    q2x = px + h * pvx; q2y = py + h * pvy
    q2vx = pvx + h * d1vx; q2vy = pvy + h * d1vy
    a2x, a2y, j2xx, j2yy, j2xy = accel_jac(mu, s2x, s2y, k2x, k2y)
    d2vx = j2xx * q2x + j2xy * q2y + 2.0 * q2vy
    d2vy = j2xy * q2x + j2yy * q2y - 2.0 * q2vx
    s3x = x + h * k2x; s3y = y + h * k2y
    k3x = vx + h * a2x; k3y = vy + h * a2y
    q3x = px + h * q2vx; q3y = py + h * q2vy
    q3vx = pvx + h * d2vx; q3vy = pvy + h * d2vy
    a3x, a3y, j3xx, j3yy, j3xy = accel_jac(mu, s3x, s3y, k3x, k3y)
    d3vx = j3xx * q3x + j3xy * q3y + 2.0 * q3vy
    d3vy = j3xy * q3x + j3yy * q3y - 2.0 * q3vx
    s4x = x + dt * k3x; s4y = y + dt * k3y
    k4x = vx + dt * a3x; k4y = vy + dt * a3y
    q4x = px + dt * q3vx; q4y = py + dt * q3vy
    q4vx = pvx + dt * d3vx; q4vy = pvy + dt * d3vy
    a4x, a4y, j4xx, j4yy, j4xy = accel_jac(mu, s4x, s4y, k4x, k4y)
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

function survival(mu::Float64, a::Float64, e::Float64, horizon::Float64, stepsPerPeriod::Float64)
    rp = a * (1.0 - e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x
    dt = 2.0 * pi * (a * Base.sqrt(a)) / stepsPerPeriod
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0
    t = 0.0
    while t < horizon
        x, y, vx, vy = rk4_step(mu, dt, x, y, vx, vy)
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

function survival_fli(mu::Float64, a::Float64, e::Float64, horizon::Float64, stepsPerPeriod::Float64)
    rp = a * (1.0 - e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = Base.sqrt((1.0 - mu) * (1.0 + e) / rp) - x
    px, py, pvx, pvy = 0.5, 0.5, 0.5, 0.5
    dt = 2.0 * pi * (a * Base.sqrt(a)) / stepsPerPeriod
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0
    t = 0.0
    accLog = 0.0
    maxLog = 0.0
    n = 0
    while t < horizon
        x, y, vx, vy, px, py, pvx, pvy = rk4_step8(mu, dt, x, y, vx, vy, px, py, pvx, pvy)
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

end # module
