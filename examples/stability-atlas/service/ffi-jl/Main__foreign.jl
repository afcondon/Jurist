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
