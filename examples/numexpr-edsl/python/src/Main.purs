-- | The **Node / JavaScript** denotation of the Tier-2 eDSL.
-- |
-- | This workspace depends only on `numexpr-core` — the backend-agnostic
-- | description (`Data.NumExpr`, `Data.SystemSpec`) and its FFI-free pure
-- | denotation `integratePure`. It never imports a `*.Julia` module, so it
-- | links and runs on the stock JavaScript backend with no Julia, no purejl, no
-- | native code. That it runs at all *is* the point: the same typed `lorenz`
-- | description that Julia compiles to a native RGF + RK4 also evaluates here,
-- | in plain PureScript-on-Node — "one description, many denotations" (ADR-0007),
-- | the develop-anywhere half of the doctrine made literal.
-- |
-- | Lorenz's RHS is pure +,-,* (no transcendentals), so the RK4 here runs the
-- | same IEEE-754 double arithmetic, in the same step order, as the Julia
-- | `integrateJ` — the two orbits are expected bit-identical (the prior session
-- | measured `max abs diff 0.0` between `integratePure` and `integrate` on
-- | Julia; this confirms the *same* `integratePure` source on a second runtime
-- | lands in the same chaotic envelope). maxZ is printed full-precision for
-- | comparison against the Julia native RK4 (`julia/` Main: maxZ ≈ 47.834).
module Main where

import Prelude

import Data.Array (length, (!!)) as Array
import Data.Foldable (foldl)
import Data.Maybe (fromMaybe)
import Data.NumExpr (NumExpr)
import Data.SystemSpec (SystemSpec, integratePure, paramVars, stateVars, system)
import Effect (Effect)
import Effect.Console (log)
import VerbsDemo (run) as VerbsDemo

-- The same row-typed Lorenz system as the Julia workspace's `Main` — a misspelt
-- field (`s.q`) would be a compile error here too. The description is identical;
-- only the denotation (`integratePure`, pure PS) differs.
lorenz
  :: SystemSpec
       ( x :: NumExpr, y :: NumExpr, z :: NumExpr )
       ( sigma :: NumExpr, rho :: NumExpr, beta :: NumExpr )
lorenz = system \s p ->
  { x: p.sigma * (s.y - s.x)
  , y: s.x * (p.rho - s.z) - s.y
  , z: s.x * s.y - p.beta * s.z
  }

main :: Effect Unit
main = do
  log "== Lorenz via integratePure — pure PureScript RK4, on the Python backend (purepy) =="
  log ("state vars: " <> show (stateVars lorenz))
  log ("param vars: " <> show (paramVars lorenz))
  let
    orbit = integratePure lorenz
      { x: 1.0, y: 1.0, z: 1.0 }
      { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
      0.01
      5000
    component i st = fromMaybe 0.0 (st Array.!! i)
    maxZ = foldl (\m st -> max m (component 2 st)) 0.0 orbit
    -- The chaotic envelope the Julia native RK4 and lorenz-leaf both produce.
    sane = 40.0 < maxZ && maxZ < 55.0
  log ("steps:                       " <> show (Array.length orbit))
  log ("first state:                 " <> show (fromMaybe [] (orbit Array.!! 0)))
  log ("last state:                  " <> show (fromMaybe [] (orbit Array.!! (Array.length orbit - 1))))
  log ("maxZ (pure-PS RK4, on purepy): " <> show maxZ)
  log ("Julia native RK4 reference:  47.834 (julia/ Main, increment 2)")
  log ("attractor in chaotic envelope (40 < maxZ < 55): " <> show sane)
  VerbsDemo.run
