-- | The stability-atlas service: a PS-on-Julia process serving the typed
-- | Atlas.Protocol WebSocket. PureScript owns the protocol — every inbound
-- | frame is decoded into ClientMsg, every outbound frame is an encoded
-- | ServerMsg, via the SAME Atlas.Protocol module the browser compiles to
-- | JS. Julia owns the socket (HTTP.jl) and the threaded sweep kernel.
-- |
-- | At boot the service cross-checks the kernel's RK4 against the pure
-- | Atlas.Dynamics oracle — the production executor must agree with the
-- | develop-anywhere denotation before it serves anyone.
module Main where

import Prelude

import Atlas.Dynamics (initialState, integrateSteps)
import Atlas.Protocol (ClientMsg(..), ServerMsg(..), decodeClientMsg, encodeServerMsg)
import Atlas.Kernel (kernelProbe, runSweep, runTrajectory)
import Data.Either (Either(..))
import Data.Number (abs)
import Effect (Effect)
import Effect.Console (log)

-- | Blocking WebSocket listener (HTTP.jl). The handler gets a send
-- | capability so one inbound message can stream many outbound frames.
foreign import serveWs :: Int -> ((String -> Effect Unit) -> String -> Effect Unit) -> Effect Unit

-- | Julia buffers redirected stdout; flush so boot lines reach the log.
foreign import consoleFlush :: Effect Unit

-- | ATLAS_PORT env override (SDI rewrites the port when lazy-spawning),
-- | falling back to the given default.
foreign import portFromEnv :: Int -> Effect Int

defaultPort :: Int
defaultPort = 3210

-- | Kernel-vs-oracle agreement, run before serving: same μ, dt, steps,
-- | initial conditions through Atlas.Dynamics.integrateSteps (pure PS,
-- | here ON Julia) and the kernel's mirrored RK4. The two are the same
-- | IEEE operations in the same order, so the tolerance is essentially
-- | bit-level.
selfTest :: Effect Unit
selfTest = do
  let mu = 9.54e-4
  let s0 = initialState mu 0.4806 0.12
  let oracle = integrateSteps mu 1.0e-3 5000 s0
  let kernel = kernelProbe mu 1.0e-3 5000 s0
  let dev = abs (oracle.x - kernel.x) + abs (oracle.y - kernel.y)
              + abs (oracle.vx - kernel.vx) + abs (oracle.vy - kernel.vy)
  if dev <= 1.0e-12
    then log ("self-test: sweep kernel agrees with pure oracle (sum dev " <> show dev <> ")")
    else log ("self-test FAILED: kernel deviates from oracle (sum dev " <> show dev <> ")")

handler :: (String -> Effect Unit) -> String -> Effect Unit
handler send raw = case decodeClientMsg raw of
  Left e -> reply (ProtocolError ("malformed ClientMsg: " <> e))
  Right msg -> case msg of
    RequestSweep spec -> do
      elapsedMs <- runSweep spec (reply <<< SweepRows)
      reply (SweepDone { elapsedMs })
    RequestTrajectory spec -> do
      runTrajectory spec (\frames -> reply (TrajFrames { frames }))
      reply TrajDone
    CancelSweep -> reply (ProtocolError "CancelSweep: nothing to cancel yet")
  where
  reply :: ServerMsg -> Effect Unit
  reply = send <<< encodeServerMsg

-- | A throwaway sweep before listening, run through the FULL reply path —
-- | kernel AND protocol encode — so Julia JIT-compiles everything at boot
-- | instead of inside the first user's request. The callback must really
-- | encode: a no-op callback warms the kernel but leaves the purejl-
-- | compiled JSON printer cold (measured: ~4.5 s on the first block).
warmup :: Effect Unit
warmup = do
  void (runSweep (spec { withFli = false }) encodeAndDiscard)
  void (runSweep (spec { withFli = true }) encodeAndDiscard)
  where
  spec = { aMin: 0.4, aMax: 0.6, eMin: 0.0, eMax: 0.1, cols: 8, rows: 4, horizonPeriods: 2.0, mu: 9.54e-4, withFli: false }

  encodeAndDiscard :: forall r. { rowStart :: Int, rows :: Array (Array Number) | r } -> Effect Unit
  encodeAndDiscard block =
    let encoded = encodeServerMsg (SweepRows { rowStart: block.rowStart, rows: block.rows })
    in when (encoded == "") (log "unreachable: empty encode")

main :: Effect Unit
main = do
  selfTest
  warmup
  port <- portFromEnv defaultPort
  log ("atlas-service: listening on ws://0.0.0.0:" <> show port)
  consoleFlush
  serveWs port handler
