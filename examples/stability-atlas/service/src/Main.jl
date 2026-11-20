# User FFI shim for module Main — the socket layer. HTTP.jl WebSocket
# listener behind one PS foreign; the handler receives a SEND CAPABILITY
# so it can stream many frames per inbound message (progressive sweep
# rows, trajectory frames), not just reply once.
#
# Conventions (lorenz-leaf): curried PS = chains of unary closures;
# Effect = zero-argument thunk. So
#   serveWs :: Int -> ((String -> Effect Unit) -> String -> Effect Unit) -> Effect Unit
# arrives as serveWs(port)(handler), and per message we run
# handler(send)(msg)() where send(str) is itself () -> ws-write.

import HTTP

serveWs(port) = handler -> () -> begin
    HTTP.WebSockets.listen("0.0.0.0", Base.Int(port)) do ws
        send = str -> () -> begin
            HTTP.WebSockets.send(ws, str)
            nothing
        end
        for msg in ws
            handler(send)(Base.String(msg))()
        end
    end
    nothing
end

# consoleFlush :: Effect Unit — Julia buffers redirected stdout; the
# service flushes after boot-time log lines so launchd/nohup logs appear.
consoleFlush = () -> begin
    Base.flush(Base.stdout)
    nothing
end

# portFromEnv :: Int -> Effect Int — ATLAS_PORT override for SDI spawns.
portFromEnv(dflt) = () ->
    Base.haskey(Base.ENV, "ATLAS_PORT") ?
        Base.parse(Base.Int, Base.ENV["ATLAS_PORT"]) :
        Base.Int(dflt)

# isCheck :: Effect Boolean — `main.jl check` runs the checks and exits
# instead of serving.
isCheck = () -> ("check" in Base.ARGS)

# The hand-written kernel this service used to run, kept in native/ as the
# reference implementation. Loaded only in check mode.
const _REFERENCE = Base.Ref{Base.Any}(nothing)
function _reference()
    if _REFERENCE[] === nothing
        Base.include(@__MODULE__, Base.joinpath(@__DIR__, "..", "..", "native", "kernel_fixed.jl"))
        _REFERENCE[] = Base.invokelatest(() -> KernelFixed)
    end
    _REFERENCE[]
end

# referenceSweep :: Boolean -> SweepSpec -> Effect (Array (Array Number))
# The same sweep through native/kernel_fixed.jl, single-threaded.
referenceSweep(fli) = spec -> () -> begin
    k = _reference()
    f = Base.invokelatest(Base.getproperty, k, fli ? :survival_fli : :survival)
    spp = Base.invokelatest(Base.getproperty, k, :STEPS_PER_PERIOD)
    cols = Base.Int(spec["cols"]); rows = Base.Int(spec["rows"])
    da = cols > 1 ? (spec["aMax"] - spec["aMin"]) / (cols - 1) : 0.0
    de = rows > 1 ? (spec["eMax"] - spec["eMin"]) / (rows - 1) : 0.0
    horizon = spec["horizonPeriods"] * 2.0 * Base.pi
    Base.Any[Base.Any[Base.invokelatest(f, spec["mu"], spec["aMin"] + da * (c - 1), spec["eMin"] + de * (r - 1), horizon, spp)
                      for c in 1:cols] for r in 1:rows]
end
