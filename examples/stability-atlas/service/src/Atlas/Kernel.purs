-- | The service's numerical entry points: the survival sweep, the
-- | single-orbit trajectory, and the chaos-indicator sweep.
-- |
-- | All three are compiled from `Atlas.Survival`, a description of the
-- | physics in PureScript. `Data.Simulation` builds the Runge-Kutta step,
-- | `Data.Simulation.Julia` has Julia compile it, and Julia's threads run
-- | the sweep. There is no hand-written integrator behind them. This module
-- | lays the grid out, asks for the runs a block of rows at a time, and
-- | turns each result into the number the atlas paints.
-- |
-- | The seam stays coarse: one crossing per block of rows or of frames,
-- | never per pixel or per step.
module Atlas.Kernel
  ( Kernel
  , RowBlock
  , compile
  , runSweep
  , runTrajectory
  , survivalRun
  , chaosAgrees
  ) where

import Prelude

import Atlas.Dynamics (jacobi)
import Atlas.Protocol (Frame, SweepSpec, TrajSpec)
import Atlas.Survival (chaos, chaosVerdict, inputs, survival, verdict)
import Data.Array (concatMap, drop, elemIndex, length, mapMaybe, slice, take, zip, zipWith, (!!), (..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (ceil, toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Simulation (Outcome, Simulation, simulate, simulation, stateNames)
import Data.Simulation.Julia (Compiled)
import Data.Simulation.Julia as Julia
import Data.Tuple (Tuple(..))
import Effect (Effect)

type RowBlock = { rowStart :: Int, rows :: Array (Array Number) }

-- | The survival run and the chaos-indicator run, compiled. The chaos run
-- | is kept as a description too, so that it can be interpreted for
-- | `chaosAgrees`, with the place of `maxLog` in its state.
newtype Kernel = Kernel
  { survival :: Compiled
  , chaos :: Compiled
  , chaosDescription :: Simulation
  , maxLogAt :: Int
  }

foreign import nowMs :: Effect Number

foreign import reportSweep
  :: { cols :: Int, rows :: Int, fli :: Boolean, total :: Number, kernel :: Number, emit :: Number }
  -> Effect Unit

-- | Compile both runs. Done once, when the service starts.
compile :: Effect (Either String Kernel)
compile = case simulation survival, simulation chaos of
  Right survivalSim, Right chaosSim -> case elemIndex "maxLog" (stateNames chaosSim) of
    Just maxLogAt -> do
      survivalCompiled <- Julia.compile survivalSim
      chaosCompiled <- Julia.compile chaosSim
      pure (Right (Kernel { survival: survivalCompiled, chaos: chaosCompiled, chaosDescription: chaosSim, maxLogAt }))
    Nothing -> pure (Left "the chaos run has no variable called maxLog")
  Left problem, _ -> pure (Left problem)
  _, Left problem -> pure (Left problem)

-- | One orbit, start to finish, with no frames kept.
survivalRun :: Kernel -> { a :: Number, e :: Number, mu :: Number, horizonPeriods :: Number } -> Effect Outcome
survivalRun (Kernel kernel) orbit = Julia.simulate kernel.survival (inputs orbit)

-- | Whether the compiled chaos run and the same description interpreted in
-- | PureScript end one orbit in exactly the same state at the same time.
chaosAgrees :: Kernel -> { a :: Number, e :: Number, mu :: Number, horizonPeriods :: Number } -> Effect { agree :: Boolean, steps :: Int }
chaosAgrees (Kernel kernel) orbit = do
  compiled <- Julia.simulate kernel.chaos (inputs orbit)
  let interpreted = simulate kernel.chaosDescription (inputs orbit)
  pure
    { agree: compiled.state == interpreted.state && compiled.time == interpreted.time && compiled.event == interpreted.event
    , steps: interpreted.steps
    }

-- | Run a sweep; the callback fires once per computed block of rows, in
-- | row order. Returns elapsed wall-clock milliseconds.
runSweep :: Kernel -> SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number
runSweep (Kernel kernel) spec emit = do
  started <- nowMs
  spent <- go 0 { kernel: 0.0, emit: 0.0 }
  finished <- nowMs
  let total = finished - started
  reportSweep { cols: spec.cols, rows: spec.rows, fli: spec.withFli, total, kernel: spent.kernel, emit: spent.emit }
  pure total
  where
  compiled = if spec.withFli then kernel.chaos else kernel.survival

  paint time event state =
    if spec.withFli then
      chaosVerdict spec.horizonPeriods { time, event, maxLog: fromMaybe 0.0 (state !! kernel.maxLogAt) }
    else verdict spec.horizonPeriods { time, event }

  da = if spec.cols > 1 then (spec.aMax - spec.aMin) / toNumber (spec.cols - 1) else 0.0
  de = if spec.rows > 1 then (spec.eMax - spec.eMin) / toNumber (spec.rows - 1) else 0.0

  -- About forty blocks to a sweep, so the picture fills in as it is
  -- computed, and never fewer than eight rows, so every thread has work.
  blockRows = max 8 (ceil (toNumber spec.rows / 40.0))

  orbit row column = inputs
    { a: spec.aMin + da * toNumber column
    , e: spec.eMin + de * toNumber row
    , mu: spec.mu
    , horizonPeriods: spec.horizonPeriods
    }

  go rowStart spent =
    if rowStart >= spec.rows then pure spent
    else do
      let
        rowEnd = min spec.rows (rowStart + blockRows)
        rowNumbers = rowStart .. (rowEnd - 1)
        columns = if spec.cols > 0 then 0 .. (spec.cols - 1) else []
      before <- nowMs
      swept <- Julia.sweep compiled (concatMap (\row -> map (orbit row) columns) rowNumbers)
      let
        verdicts = zipWith (\(Tuple time event) state -> paint time event state) (zip swept.times swept.events) swept.states
        rows = map (\i -> slice (i * spec.cols) ((i + 1) * spec.cols) verdicts) (0 .. (rowEnd - rowStart - 1))
      computed <- nowMs
      emit { rowStart, rows }
      emitted <- nowMs
      go rowEnd { kernel: spent.kernel + (computed - before), emit: spent.emit + (emitted - computed) }

-- | Integrate one orbit; the callback fires once per block of frames, in
-- | order. A frame is kept at the start, after every `frameStride` steps,
-- | and at the step where the orbit escapes or meets Jupiter. The browser
-- | replays the orbit a stride at a time, so a run that reaches the horizon
-- | part-way through a stride ends at its last whole one.
runTrajectory :: Kernel -> TrajSpec -> (Array Frame -> Effect Unit) -> Effect Unit
runTrajectory kernel@(Kernel compiled) spec emit = do
  outcome <- survivalRun kernel orbit
  frames <- Julia.trajectory compiled.survival stride (inputs orbit)
  let
    partial = outcome.event == Nothing && outcome.steps `mod` stride /= 0
    kept = if partial then take (length frames - 1) frames else frames
  emitBlocks (mapMaybe toFrame kept)
  where
  orbit = { a: spec.a, e: spec.e, mu: spec.mu, horizonPeriods: spec.horizonPeriods }
  stride = max 1 spec.frameStride

  toFrame frame = case frame.state of
    [ x, y, vx, vy ] -> Just { t: frame.time, x, y, vx, vy, jacobi: jacobi spec.mu { x, y, vx, vy } }
    _ -> Nothing

  emitBlocks frames = case Array.null frames of
    true -> pure unit
    false -> do
      emit (take framesPerBlock frames)
      emitBlocks (drop framesPerBlock frames)

framesPerBlock :: Int
framesPerBlock = 256
