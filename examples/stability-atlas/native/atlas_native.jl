#!/usr/bin/env julia
#
# NATIVE REFERENCE (a) — the stability atlas with no PureScript in it.
#
# A drop-in replacement for `service/`: same WebSocket, same Atlas.Protocol
# messages on the wire, same fixed-step RK4 kernel. What differs is the whole
# harness above the numerics — the protocol is Julia structs, the codec is
# JSON3, the socket is driven directly rather than through a PS `Effect`
# chain. Point the atlas frontend at this port and it works unchanged.
#
# That is the measurement: with the arithmetic held bit-for-bit fixed
# (`kernel_fixed.jl` is a verbatim copy of the shim), the gap between this
# service and the polyglot one is exactly what compiling the protocol layer
# from PureScript to Julia costs. Nothing else varies.
#
#   julia --project=. -t auto atlas_native.jl        # :3212
#
# Emits the same `sweep-perf` diagnostic line on stderr as the polyglot
# service, so `compare.jl` reads both the same way.

using HTTP
using JSON3

include("kernel_fixed.jl")
using .KernelFixed

const DEFAULT_PORT = 3212

# --- protocol ----------------------------------------------------------------
#
# The polyglot service gets this from Atlas.Protocol, one PureScript module
# compiled to both ends of the wire. Here it is written twice by hand — once
# as these structs, once as whatever the browser believes — which is precisely
# the drift the exhibit's thesis is about. Kept faithful so the comparison is
# about cost, not about capability.

struct SweepSpec
    aMin::Float64
    aMax::Float64
    eMin::Float64
    eMax::Float64
    cols::Int
    rows::Int
    horizonPeriods::Float64
    mu::Float64
    withFli::Bool
end

struct TrajSpec
    a::Float64
    e::Float64
    horizonPeriods::Float64
    mu::Float64
    frameStride::Int
end

sweep_spec(o) = SweepSpec(
    Float64(o.aMin), Float64(o.aMax), Float64(o.eMin), Float64(o.eMax),
    Int(o.cols), Int(o.rows), Float64(o.horizonPeriods), Float64(o.mu),
    Bool(o.withFli))

traj_spec(o) = TrajSpec(
    Float64(o.a), Float64(o.e), Float64(o.horizonPeriods), Float64(o.mu),
    Int(o.frameStride))

# --- instrumentation ---------------------------------------------------------

const SWEEP_PERF = Dict{String, Float64}("kernel" => 0.0, "emit" => 0.0, "total" => 0.0)

# --- sweep -------------------------------------------------------------------

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
                    survival_fli(spec.mu, a, e, horizon, STEPS_PER_PERIOD) :
                    survival(spec.mu, a, e, horizon, STEPS_PER_PERIOD)
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
        " fli=", spec.withFli,
        " total_ms=", total,
        " kernel_ms=", SWEEP_PERF["kernel"],
        " emit_ms=", SWEEP_PERF["emit"])
    flush(stderr)
    total
end

# --- trajectory --------------------------------------------------------------

const TRAJ_BLOCK = 256

function run_traj(spec::TrajSpec, emit)
    horizon = spec.horizonPeriods * 2.0 * pi
    stride = max(1, spec.frameStride)
    mu = spec.mu

    rp = spec.a * (1.0 - spec.e)
    x = rp - mu
    y = 0.0
    vx = 0.0
    vy = sqrt((1.0 - mu) * (1.0 + spec.e) / rp) - x
    dt = 2.0 * pi * (spec.a * sqrt(spec.a)) / STEPS_PER_PERIOD
    rHillSq = (mu / 3.0)^(2.0 / 3.0)
    rEscSq = 9.0

    frame(t) = begin
        dx1 = x + mu
        dx2 = x - 1.0 + mu
        r1 = sqrt(dx1 * dx1 + y * y)
        r2 = sqrt(dx2 * dx2 + y * y)
        jac = x * x + y * y + 2.0 * (1.0 - mu) / r1 + 2.0 * mu / r2 - vx * vx - vy * vy
        (t = t, x = x, y = y, vx = vx, vy = vy, jacobi = jac)
    end

    block = [frame(0.0)]
    t = 0.0
    alive = true
    while alive && t < horizon
        for _ in 1:stride
            x, y, vx, vy = rk4_step(mu, dt, x, y, vx, vy)
            t += dt
            dx1 = x + mu
            dx2 = x - 1.0 + mu
            if dx1 * dx1 + y * y > rEscSq || dx2 * dx2 + y * y < rHillSq
                alive = false
                break
            end
        end
        push!(block, frame(t))
        if length(block) >= TRAJ_BLOCK
            emit(block)
            block = typeof(block)()
        end
    end
    isempty(block) || emit(block)
    nothing
end

# --- service -----------------------------------------------------------------

function handle(send, raw::String)
    msg = try
        JSON3.read(raw)
    catch err
        send(JSON3.write((tag = "ProtocolError", message = "malformed ClientMsg: $err")))
        return
    end
    tag = get(msg, :tag, nothing)
    if tag == "RequestSweep"
        spec = sweep_spec(msg)
        elapsedMs = run_sweep(spec, (rowStart, rows) ->
            send(JSON3.write((tag = "SweepRows", rowStart = rowStart, rows = rows))))
        send(JSON3.write((tag = "SweepDone", elapsedMs = elapsedMs)))
    elseif tag == "RequestTrajectory"
        spec = traj_spec(msg)
        run_traj(spec, frames -> send(JSON3.write((tag = "TrajFrames", frames = frames))))
        send(JSON3.write((tag = "TrajDone",)))
    elseif tag == "CancelSweep"
        send(JSON3.write((tag = "ProtocolError", message = "CancelSweep: nothing to cancel yet")))
    else
        send(JSON3.write((tag = "ProtocolError", message = "unknown ClientMsg tag: $tag")))
    end
end

# The polyglot service warms the FULL reply path at boot — kernel AND protocol
# encode — because Julia would otherwise JIT the purejl-compiled JSON printer
# inside the first user's request. Same hazard here, same fix, so that neither
# side is measured cold.
function warmup()
    for fli in (false, true)
        spec = SweepSpec(0.4, 0.6, 0.0, 0.1, 8, 4, 2.0, 9.54e-4, fli)
        run_sweep(spec, (rowStart, rows) ->
            JSON3.write((tag = "SweepRows", rowStart = rowStart, rows = rows)))
    end
    run_traj(TrajSpec(0.45, 0.05, 1.0, 9.54e-4, 4),
        frames -> JSON3.write((tag = "TrajFrames", frames = frames)))
    nothing
end

function main()
    port = haskey(ENV, "ATLAS_NATIVE_PORT") ? parse(Int, ENV["ATLAS_NATIVE_PORT"]) : DEFAULT_PORT
    warmup()
    println("atlas-native: listening on ws://0.0.0.0:$port")
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
