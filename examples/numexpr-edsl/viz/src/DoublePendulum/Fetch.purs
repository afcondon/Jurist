-- | Load the trajectory JSON written by the Julia backend. The whole physics
-- | computation (an index-1 DAE solved by ModelingToolkit) already ran in
-- | Julia; this frontend only consumes the resulting frames.
module DoublePendulum.Fetch
  ( Trajectory
  , loadTrajectory
  ) where

import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)

-- | One frame is `[x1, y1, x2, y2]` (Cartesian bob positions); `l1`/`l2` are the
-- | rod lengths (for scaling). Extra JSON fields (times, vars, t0/t1) are
-- | ignored.
type Trajectory =
  { l1 :: Number
  , l2 :: Number
  , frames :: Array (Array Number)
  }

foreign import loadTrajectory_ :: String -> EffectFnAff Trajectory

loadTrajectory :: String -> Aff Trajectory
loadTrajectory url = fromEffectFnAff (loadTrajectory_ url)
