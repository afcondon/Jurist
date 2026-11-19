-- | The systems this example runs, the inputs it runs them with, and what
-- | it says about a run. Shared by the Julia program and the Node one, so
-- | that "the same run" means the same description and the same inputs.
module Systems
  ( Case
  , cases
  , report
  ) where

import Prelude

import Atlas.Survival as Atlas
import Data.Array (range)
import Data.Int (toNumber)
import Data.NumExpr (num, var)
import Data.Simulation (Outcome, Spec)
import Data.Tuple (Tuple(..))

type Case = { title :: String, spec :: Spec, rows :: Array (Array Number) }

cases :: Array Case
cases =
  [ { title: "Lorenz, 2000 steps"
    , spec: lorenz
    , rows: [ [ 10.0, 28.0, 8.0 / 3.0, 0.01, 20.0 ] ]
    }
  , { title: "falling body, stopped by an event"
    , spec: fall
    , rows: [ [ 100.0, 0.02, 0.001 ] ]
    }
  , { title: "three-body survival, 4 x 3 orbits, 20 periods"
    , spec: Atlas.survival
    , rows: grid
    }
  ]

-- | What is said of one run, by whichever runtime computed it. The numbers
-- | are printed in full, so two runtimes print the same lines only if they
-- | computed the same doubles.
report :: Outcome -> Array String
report outcome =
  [ "  first run: " <> show outcome.steps <> " steps to t = " <> show outcome.time
  , "  its final state: " <> show outcome.state
  ]

lorenz :: Spec
lorenz =
  { inputs: [ "sigma", "rho", "beta", "dt", "until" ]
  , derived: []
  , state:
      [ { name: "x", initial: one, rate: var "sigma" * (y - x) }
      , { name: "y", initial: one, rate: x * (var "rho" - z) - y }
      , { name: "z", initial: one, rate: x * y - var "beta" * z }
      ]
  , timeStep: var "dt"
  , horizon: var "until"
  , events: []
  }
  where
  x = var "x"
  y = var "y"
  z = var "z"

-- A falling body with quadratic drag, stopped when it reaches the ground.
fall :: Spec
fall =
  { inputs: [ "height", "drag", "dt" ]
  , derived: []
  , state:
      [ { name: "y", initial: var "height", rate: v }
      , { name: "v", initial: zero, rate: var "drag" * v * v - num 9.81 }
      ]
  , timeStep: var "dt"
  , horizon: num 60.0
  , events: [ Tuple "landed" (zero - var "y") ]
  }
  where
  v = var "v"

-- A corner of the atlas's own sweep.
grid :: Array (Array Number)
grid = do
  row <- range 0 2
  column <- range 0 3
  pure
    ( Atlas.inputs
        { a: 0.30 + 0.55 * toNumber column / 3.0
        , e: 0.35 * toNumber row / 2.0
        , mu: 9.54e-4
        , horizonPeriods: 20.0
        }
    )
