-- | The service's numerical entry points: the survival sweep, the
-- | single-orbit trajectory, and the chaos-indicator sweep.
-- |
-- | The first two are compiled from `Atlas.Survival`, a description of the
-- | physics in PureScript. `Data.Simulation` builds the Runge-Kutta step,
-- | `Data.Simulation.Julia` has Julia compile it, and Julia's threads run
-- | the sweep. There is no hand-written integrator behind them. This module
-- | lays the grid out, asks for the runs a block of rows at a time, and
-- | turns each result into the number the atlas paints.
-- |
-- | The chaos-indicator sweep (`withFli`) is still a hand-written Julia
-- | kernel, in `Kernel.jl`. It needs a conditional the expression language
-- | does not have yet.
-- |
-- | The seam stays coarse either way: one crossing per block of rows or of
-- | frames, never per pixel or per step.
module Atlas.Kernel
  ( Kernel
  , RowBlock
  , compile
  , runSweep
  , runTrajectory
  , survivalRun
  ) where

import Prelude

import Atlas.Dynamics (jacobi)
import Atlas.Protocol (Frame, SweepSpec, TrajSpec)
import Atlas.Survival (inputs, survival, verdict)
import Data.Array (concatMap, drop, length, mapMaybe, slice, take, zipWith, (..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (ceil, toNumber)
import Data.Maybe (Maybe(..))
import Data.Simulation (Outcome, simulation)
import Data.Simulation.Julia (Compiled)
import Data.Simulation.Julia as Julia
import Effect (Effect)

type RowBlock = { rowStart :: Int, rows :: Array (Array Number) }

-- | The survival run, compiled.
newtype Kernel = Kernel Compiled

foreign import runSweepFliImpl :: SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number

foreign import nowMs :: Effect Number

foreign import reportSweep
  :: { cols :: Int, rows :: Int, fli :: Boolean, total :: Number, kernel :: Number, emit :: Number }
  -> Effect Unit

-- | Compile the survival run. Done once, when the service starts.
compile :: Effect (Either String Kernel)
compile = case simulation survival of
  Left problem -> pure (Left problem)
  Right sim -> Right <<< Kernel <$> Julia.compile sim

-- | One orbit, start to finish, with no frames kept.
survivalRun :: Kernel -> { a :: Number, e :: Number, mu :: Number, horizonPeriods :: Number } -> Effect Outcome
survivalRun (Kernel compiled) orbit = Julia.simulate compiled (inputs orbit)

-- | Run a sweep; the callback fires once per computed block of rows, in
-- | row order. Returns elapsed wall-clock milliseconds.
runSweep :: Kernel -> SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number
runSweep (Kernel compiled) spec emit =
  if spec.withFli then runSweepFliImpl spec emit
  else do
    started <- nowMs
    spent <- go 0 { kernel: 0.0, emit: 0.0 }
    finished <- nowMs
    let total = finished - started
    reportSweep { cols: spec.cols, rows: spec.rows, fli: false, total, kernel: spent.kernel, emit: spent.emit }
    pure total
  where
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
        verdicts = zipWith (\time event -> verdict spec.horizonPeriods { time, event }) swept.times swept.events
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
  frames <- Julia.trajectory compiled stride (inputs orbit)
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
