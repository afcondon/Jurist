-- | The stability-atlas service: a PS-on-Julia process serving the typed
-- | Atlas.Protocol WebSocket. PureScript owns the protocol (every inbound
-- | frame is decoded into ClientMsg, every outbound frame is an encoded
-- | ServerMsg, by the same Atlas.Protocol module the browser compiles to
-- | JS) and the physics, which Julia compiles from `Atlas.Survival`. Julia
-- | owns the socket (HTTP.jl), the native code and the threads.
-- |
-- | Before it serves, the service checks that the compiled kernel and the
-- | pure `Atlas.Dynamics` the browser runs agree exactly.
-- |
-- | `julia output-jl/main.jl check` runs the checks in `check` and exits;
-- | `bin/demos.py` holds their output to `expected-output.txt`.
module Main where

import Prelude

import Atlas.Dynamics (asteroidPeriod, initialState, integrateSteps, stepsPerPeriod)
import Atlas.Kernel (Kernel, chaosAgrees, compile, runSweep, runTrajectory, survivalRun)
import Atlas.Protocol (ClientMsg(..), Frame, ServerMsg(..), SweepSpec, decodeClientMsg, encodeServerMsg)
import Data.Array (concat, filter, length, mapWithIndex, zipWith, (!!))
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Number (abs)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref

-- | Blocking WebSocket listener (HTTP.jl). The handler gets a send
-- | capability so one inbound message can stream many outbound frames.
foreign import serveWs :: Int -> ((String -> Effect Unit) -> String -> Effect Unit) -> Effect Unit

-- | Julia buffers redirected stdout; flush so boot lines reach the log.
foreign import consoleFlush :: Effect Unit

-- | ATLAS_PORT env override (SDI rewrites the port when lazy-spawning),
-- | falling back to the given default.
foreign import portFromEnv :: Int -> Effect Int

foreign import isCheck :: Effect Boolean

-- | A sweep through the hand-written reference in `native/kernel_fixed.jl`.
foreign import referenceSweep :: Boolean -> SweepSpec -> Effect (Array (Array Number))

defaultPort :: Int
defaultPort = 3210

mu :: Number
mu = 9.54e-4

-- | The compiled kernel against `Atlas.Dynamics`, which is what the browser
-- | steps an orbit with: the same orbit, the same number of steps, and the
-- | states must be equal, not close. Returns whether they were.
selfTest :: Kernel -> Effect Boolean
selfTest kernel = do
  outcome <- survivalRun kernel { a, e, mu, horizonPeriods: 6.0 }
  let
    oracle = integrateSteps mu (asteroidPeriod a / stepsPerPeriod) outcome.steps (initialState mu a e)
    same = outcome.state == [ oracle.x, oracle.y, oracle.vx, oracle.vy ]
  log
    ( if same then "self-test: the compiled kernel and Atlas.Dynamics agree exactly after "
        <> show outcome.steps
        <> " steps"
      else "self-test FAILED: the compiled kernel and Atlas.Dynamics disagree after "
        <> show outcome.steps
        <> " steps"
    )
  pure same
  where
  a = 0.4806
  e = 0.12

handler :: Kernel -> (String -> Effect Unit) -> String -> Effect Unit
handler kernel send raw = case decodeClientMsg raw of
  Left e -> reply (ProtocolError ("malformed ClientMsg: " <> e))
  Right msg -> case msg of
    RequestSweep spec -> do
      elapsedMs <- runSweep kernel spec (reply <<< SweepRows)
      reply (SweepDone { elapsedMs })
    RequestTrajectory spec -> do
      runTrajectory kernel spec (\frames -> reply (TrajFrames { frames }))
      reply TrajDone
    CancelSweep -> reply (ProtocolError "CancelSweep: nothing to cancel yet")
  where
  reply :: ServerMsg -> Effect Unit
  reply = send <<< encodeServerMsg

-- | A throwaway sweep before listening, run through the full reply path,
-- | kernel and protocol encode, so Julia compiles everything at boot
-- | instead of inside the first user's request. The callback must really
-- | encode: a no-op callback warms the kernel but leaves the JSON printer
-- | cold (measured: ~4.5 s on the first block).
warmup :: Kernel -> Effect Unit
warmup kernel = do
  void (runSweep kernel (spec { withFli = false }) encodeAndDiscard)
  void (runSweep kernel (spec { withFli = true }) encodeAndDiscard)
  where
  spec = { aMin: 0.4, aMax: 0.6, eMin: 0.0, eMax: 0.1, cols: 8, rows: 4, horizonPeriods: 2.0, mu, withFli: false }

  encodeAndDiscard :: forall r. { rowStart :: Int, rows :: Array (Array Number) | r } -> Effect Unit
  encodeAndDiscard block =
    let encoded = encodeServerMsg (SweepRows { rowStart: block.rowStart, rows: block.rows })
    in when (encoded == "") (log "unreachable: empty encode")

-- | Every sweep the service can answer, collected instead of sent.
collectSweep :: Kernel -> SweepSpec -> Effect (Array (Array Number))
collectSweep kernel spec = do
  blocks <- Ref.new []
  void (runSweep kernel spec \block -> Ref.modify_ (_ <> [ block.rows ]) blocks)
  concat <$> Ref.read blocks

collectTrajectory :: Kernel -> { a :: Number, e :: Number, horizonPeriods :: Number, frameStride :: Int } -> Effect (Array Frame)
collectTrajectory kernel orbit = do
  blocks <- Ref.new []
  runTrajectory kernel { a: orbit.a, e: orbit.e, horizonPeriods: orbit.horizonPeriods, mu, frameStride: orbit.frameStride }
    \frames -> Ref.modify_ (_ <> [ frames ]) blocks
  concat <$> Ref.read blocks

-- | What the service computes, held to the two things it must agree with:
-- | the hand-written kernel it replaced, pixel for pixel, and the browser's
-- | replay of an orbit, frame for frame.
check :: Kernel -> Effect Unit
check kernel = do
  compareSweep "survival sweep, 120 x 75, 150 periods" atlasDefault
  compareSweep "chaos-indicator sweep, 120 x 75, 150 periods" (atlasDefault { withFli = true })
  interpreted <- chaosAgrees kernel { a: 0.4806, e: 0.12, mu, horizonPeriods: 6.0 }
  log "== the chaos-indicator run, interpreted in PureScript =="
  log ("  identical to the compiled run after " <> show interpreted.steps <> " steps: " <> show interpreted.agree)
  replay "an orbit that survives" { a: 0.4806, e: 0.12, horizonPeriods: 30.0, frameStride: 4 }
  replay "an orbit that is lost" { a: 0.7, e: 0.3, horizonPeriods: 150.0, frameStride: 4 }
  where
  atlasDefault =
    { aMin: 0.30, aMax: 0.85, eMin: 0.0, eMax: 0.35, cols: 120, rows: 75, horizonPeriods: 150.0, mu, withFli: false }

  compareSweep title spec = do
    mine <- concat <$> collectSweep kernel spec
    reference <- concat <$> referenceSweep spec.withFli spec
    let same = length (filter identity (zipWith (==) mine reference))
    log ("== " <> title <> " ==")
    log ("  survivors: " <> show (length (filter (_ >= 1.0) mine)) <> " of " <> show (length mine))
    log ("  identical to native/kernel_fixed.jl: " <> show same <> " of " <> show (length reference))

  -- Step the orbit with `Atlas.Dynamics.rk4Step`, as the browser does, and
  -- require every frame the service sent to be exactly that state: a whole
  -- stride of steps per frame, and for a lost orbit the step it was lost at.
  replay title orbit = do
    frames <- collectTrajectory kernel orbit
    outcome <- survivalRun kernel { a: orbit.a, e: orbit.e, mu, horizonPeriods: orbit.horizonPeriods }
    let
      dt = asteroidPeriod orbit.a / stepsPerPeriod
      start = initialState mu orbit.a orbit.e
      last = length frames - 1
      stepsAt i = case outcome.event of
        Just _ | i == last -> outcome.steps
        _ -> i * orbit.frameStride
      matches = mapWithIndex (\i frame -> sameState frame (integrateSteps mu dt (stepsAt i) start)) frames
      drift = case frames !! 0 of
        Just first -> foldl (\worst f -> max worst (abs (f.jacobi - first.jacobi) / abs first.jacobi)) 0.0 frames
        Nothing -> 0.0
    log ("== " <> title <> " (a = " <> show orbit.a <> ", e = " <> show orbit.e <> ") ==")
    log ("  steps: " <> show outcome.steps <> ", frames: " <> show (length frames))
    log ("  frames Atlas.Dynamics reproduces exactly: "
      <> show (length (filter identity matches)) <> " of " <> show (length frames))
    log ("  largest relative drift of the Jacobi constant: " <> show drift)

  sameState frame s = frame.x == s.x && frame.y == s.y && frame.vx == s.vx && frame.vy == s.vy

main :: Effect Unit
main = compile >>= case _ of
  Left problem -> log ("atlas-service: the kernels did not compile: " <> problem)
  Right kernel -> do
    agreed <- selfTest kernel
    checking <- isCheck
    if checking then check kernel
    else when agreed do
      warmup kernel
      port <- portFromEnv defaultPort
      log ("atlas-service: listening on ws://0.0.0.0:" <> show port)
      consoleFlush
      serveWs port (handler kernel)
