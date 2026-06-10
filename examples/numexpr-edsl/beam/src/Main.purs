-- | The **BEAM / Erlang** denotation of the Tier-2 eDSL.
-- |
-- | Like `node/`, this workspace depends only on `numexpr-core` — the
-- | backend-agnostic description and its FFI-free pure denotation
-- | `integratePure`. It never imports a `*.Julia` module. Here the backend is
-- | `purs-backend-erl`: stock `purs` compiles `core` to CoreFn, then
-- | purs-backend-erl transforms it to Erlang and it runs on the BEAM — a *third*
-- | runtime for the same typed `lorenz` description, beside Julia and Node
-- | (ADR-0007, "one description, many denotations").
-- |
-- | Lorenz's RHS is pure +,-,* (no transcendentals), so the RK4 here runs the
-- | same IEEE-754 double arithmetic, in the same step order, as the Julia
-- | `integrateJ` and the Node run — the orbits land in the same chaotic
-- | envelope, maxZ ≈ 47.834.
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

-- The same row-typed Lorenz system as the Julia and Node workspaces — one
-- description, denoted here onto the BEAM.
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
  log "== Lorenz via integratePure — pure PureScript RK4, on the BEAM (purs-backend-erl) =="
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
    sane = 40.0 < maxZ && maxZ < 55.0
  log ("steps:                       " <> show (Array.length orbit))
  log ("first state:                 " <> show (fromMaybe [] (orbit Array.!! 0)))
  log ("last state:                  " <> show (fromMaybe [] (orbit Array.!! (Array.length orbit - 1))))
  log ("maxZ (pure-PS RK4, on BEAM): " <> show maxZ)
  log ("Julia native RK4 reference:  47.834 (julia/ Main, increment 2)")
  log ("attractor in chaotic envelope (40 < maxZ < 55): " <> show sane)
  VerbsDemo.run
