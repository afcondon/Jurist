# FFI for Data.Simulation.Julia.
#
# This file holds no numerical method. The statements it receives were
# built in PureScript by Data.Simulation.simulation; it wraps them in the
# loop that module documents and compiles the result with
# RuntimeGeneratedFunctions. The loop here and the one in
# Data.Simulation.simulate are the two places that loop is written, and
# examples/staged-integrator holds them to the same outcomes bit for bit.
#
#   Compiled == (run, record, source text, number of state variables)
#     run(input::Vector{Float64})            -> (time, event, steps, state...)
#     record(input::Vector{Float64}, stride) -> Vector of (time, state...)
#
# Names: slot i of the start program is a<i>, of the step program b<i>, of
# the kth update u<k>_<i>. The step program's inputs are the state, then
# the constants, then the time step, so b0..b(ns-1) are the state the loop
# carries; an update's inputs are the state and the constants.

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

jAssign(name) = expr -> Base.Expr(:(=), Base.Symbol(name), expr)

function _simulation_expr(spec, record::Bool)
    nin = Base.Int(spec["inputs"])
    ns = Base.Int(spec["states"])
    nc = Base.Int(spec["constants"])
    ne = Base.Int(spec["events"])
    so = spec["startOutputs"]
    po = spec["stepOutputs"]
    b(i) = Base.Symbol("b", i)
    float(x) = Base.Expr(:call, Base.GlobalRef(Base, :Float64), x)
    push = Base.GlobalRef(Base, :push!)

    body = Base.Any[]
    for i in 1:nin
        Base.push!(body, Base.Expr(:(=), Base.Symbol("a", i - 1), Base.Expr(:ref, :input, i)))
    end
    Base.append!(body, spec["start"])
    Base.push!(body, :(dt = $(float(so[1]))))
    Base.push!(body, :(horizon = $(float(so[2]))))
    for j in 1:(ns + nc)
        Base.push!(body, Base.Expr(:(=), b(j - 1), float(so[2 + j])))
    end
    Base.push!(body, Base.Expr(:(=), b(ns + nc), :dt))
    Base.push!(body, :(time = 0.0))
    Base.push!(body, :(fired = -1))
    Base.push!(body, :(steps = 0))

    state = Base.Expr(:tuple, [b(j - 1) for j in 1:ns]...)
    frame = Base.Expr(:tuple, :time, [b(j - 1) for j in 1:ns]...)
    if record
        Base.push!(body, :(frames = [$frame]))
    end

    loop = Base.Any[]
    Base.append!(loop, spec["step"])
    # Every output is read before any state variable is written.
    outs = Base.Expr(:tuple, [float(po[j]) for j in 1:(ns + ne)]...)
    names = Base.Expr(:tuple, [b(j - 1) for j in 1:ns]..., [Base.Symbol("event", k) for k in 1:ne]...)
    Base.push!(loop, Base.Expr(:(=), names, outs))
    Base.push!(loop, :(time += dt))
    Base.push!(loop, :(steps += 1))
    for k in ne:-1:1
        ev = Base.Symbol("event", k)
        Base.push!(loop, :(if $ev > 0.0
            fired = $(k - 1)
        end))
    end
    for update in spec["updates"]
        u(i) = Base.Symbol(update["prefix"], i)
        block = Base.Any[]
        for j in 1:(ns + nc)
            Base.push!(block, Base.Expr(:(=), u(j - 1), b(j - 1)))
        end
        Base.append!(block, update["body"])
        Base.push!(block, Base.Expr(:(=),
            Base.Expr(:tuple, [b(j - 1) for j in 1:ns]...),
            Base.Expr(:tuple, [float(update["outputs"][j]) for j in 1:ns]...)))
        every = Base.Int(update["every"])
        Base.push!(loop, :(if fired < 0 && steps % $every == 0
            $(Base.Expr(:block, block...))
        end))
    end
    if record
        Base.push!(loop, :(if fired >= 0 || steps % stride == 0
            $push(frames, $frame)
        end))
    end
    Base.push!(loop, :(if fired >= 0
        break
    end))
    Base.push!(body, Base.Expr(:while, :(time < horizon), Base.Expr(:block, loop...)))

    if record
        Base.push!(body, :(if fired < 0 && steps % stride != 0
            $push(frames, $frame)
        end))
        Base.push!(body, :frames)
        Base.Expr(:->, Base.Expr(:tuple, :input, :stride), Base.Expr(:block, body...))
    else
        Base.push!(body, Base.Expr(:tuple, :time, :fired, :steps, [b(j - 1) for j in 1:ns]...))
        Base.Expr(:->, Base.Expr(:tuple, :input), Base.Expr(:block, body...))
    end
end

# compileJ :: Lowered -> Effect Compiled
compileJ(spec) = () -> begin
    run_expr = _simulation_expr(spec, false)
    record_expr = _simulation_expr(spec, true)
    run = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(run_expr)
    record = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(record_expr)
    text = Base.string(Base.remove_linenums!(Base.copy(run_expr)))
    (run, record, text, Base.Int(spec["states"]))
end

_floats(xs) = Base.Float64[x for x in xs]

# simulateJ :: Compiled -> Array Number -> Effect RawOutcome
simulateJ(compiled) = inputs -> () -> begin
    r = compiled[1](_floats(inputs))
    Base.Dict{Base.String, Base.Any}(
        "time" => r[1], "event" => r[2], "steps" => r[3],
        "state" => Base.Any[r[3 + j] for j in 1:compiled[4]])
end

# sweepJ :: Compiled -> Array (Array Number) -> Effect Sweep
# One run per row, across the threads Julia was started with.
sweepJ(compiled) = rows -> () -> _sweep(compiled[1], [_floats(r) for r in rows], compiled[4])

function _sweep(run, rows::Base.Vector{Base.Vector{Float64}}, ns::Base.Int)
    n = Base.length(rows)
    times = Base.Vector{Float64}(undef, n)
    events = Base.Vector{Base.Int}(undef, n)
    steps = Base.Vector{Base.Int}(undef, n)
    states = Base.Matrix{Float64}(undef, ns, n)
    Base.Threads.@threads for i in 1:n
        r = run(rows[i])
        times[i] = r[1]
        events[i] = r[2]
        steps[i] = r[3]
        for j in 1:ns
            states[j, i] = r[3 + j]
        end
    end
    Base.Dict{Base.String, Base.Any}(
        "times" => Base.Any[x for x in times],
        "events" => Base.Any[x for x in events],
        "steps" => Base.Any[x for x in steps],
        "states" => Base.Any[Base.Any[states[j, i] for j in 1:ns] for i in 1:n])
end

# trajectoryJ :: Compiled -> Int -> Array Number -> Effect (Array Frame)
trajectoryJ(compiled) = stride -> inputs -> () -> begin
    frames = compiled[2](_floats(inputs), Base.Int(stride))
    Base.Any[Base.Dict{Base.String, Base.Any}(
                 "time" => f[1], "state" => Base.Any[f[1 + j] for j in 1:compiled[4]])
             for f in frames]
end

# sourceJ :: Compiled -> String
sourceJ(compiled) = compiled[3]
