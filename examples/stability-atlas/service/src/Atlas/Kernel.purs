-- | The hot kernel's PS face: both numerical entry points of the service.
-- | Descriptions (SweepSpec / TrajSpec) cross the seam once; Julia owns
-- | the inner loops (threaded RK4 with escape and Hill-sphere events,
-- | mirroring Atlas.Dynamics.rk4Step exactly); results come back coarse-
-- | grained — one callback per row block or frame block, never per pixel
-- | or per step (ADR-0007: descriptions across, handles back).
module Atlas.Kernel
  ( RowBlock
  , runSweep
  , runTrajectory
  , kernelProbe
  ) where

import Prelude

import Atlas.Dynamics (State)
import Atlas.Protocol (Frame, SweepSpec, TrajSpec)
import Effect (Effect)

type RowBlock = { rowStart :: Int, rows :: Array (Array Number) }

-- | Run a sweep; the callback fires once per computed row block (in row
-- | order). Returns elapsed wall-clock milliseconds.
foreign import runSweepImpl :: SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number

runSweep :: SweepSpec -> (RowBlock -> Effect Unit) -> Effect Number
runSweep = runSweepImpl

-- | Integrate one orbit; the callback fires once per frame block (in
-- | order). Integration ends at the horizon or at the first escape /
-- | Hill-sphere event, whichever comes first.
foreign import runTrajectoryImpl :: TrajSpec -> (Array Frame -> Effect Unit) -> Effect Unit

runTrajectory :: TrajSpec -> (Array Frame -> Effect Unit) -> Effect Unit
runTrajectory = runTrajectoryImpl

-- | The kernel's RK4, exposed for the boot-time oracle cross-check: same
-- | (mu, dt, steps, initial conditions) as Atlas.Dynamics.integrateSteps,
-- | must agree to ~1e-12 (same IEEE operations in the same order).
foreign import kernelProbe :: Number -> Number -> Int -> State -> State
