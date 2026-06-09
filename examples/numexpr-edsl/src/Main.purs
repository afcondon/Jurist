-- | Tier-2 demo, two increments:
-- |  1. stage a single `NumExpr` across the seam, compile it to a native Julia
-- |     function, and check it against the pure PS interpreter (faithful
-- |     staging — both run on Julia, so any mismatch is a staging bug);
-- |  2. lift to a row-typed `SystemSpec` (Lorenz), compile its vector field and
-- |     integrate it natively, validating the orbit against the independently
-- |     hand-written RK4 in `examples/lorenz-leaf` (maxZ ≈ 47.83).
module Main where

import Prelude

import Data.Array (elemIndex, index, length, (!!)) as Array
import Data.Foldable (foldl)
import Data.Maybe (fromMaybe)
import Data.NumExpr (NumExpr, compile, eval, evalBatch, num, render, sinE, var)
import Data.SystemSpec (SystemSpec, compileField, integrate, paramVars, stateVars, system)
import Effect (Effect)
import Effect.Console (log)

-- ── Increment 1: a single staged expression ─────────────────────────────────

expr :: NumExpr
expr = num 10.0 * (var "y" - var "x") + sinE (var "z")

vars :: Array String
vars = [ "x", "y", "z" ]

points :: Array (Array Number)
points =
  [ [ 1.0, 2.0, 0.5 ]
  , [ 0.0, 1.0, 1.0 ]
  , [ 3.0, 1.0, 2.0 ]
  , [ -1.0, 4.0, 3.14159 ]
  ]

psEval :: Array Number -> Number
psEval p = eval lookupVar expr
  where
  lookupVar s = fromMaybe 0.0 do
    i <- Array.elemIndex s vars
    Array.index p i

-- ── Increment 2: a row-typed dynamical system ───────────────────────────────

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
  log "== increment 1: NumExpr staging =="
  compiled <- compile vars expr
  jl <- evalBatch compiled points
  let ps = map psEval points
  log ("expr:             " <> render expr)
  log ("PS interp:        " <> show ps)
  log ("Julia native:     " <> show jl)
  log ("staging faithful: " <> show (ps == jl))

  log "== increment 2: Lorenz SystemSpec =="
  log ("state vars: " <> show (stateVars lorenz))
  log ("param vars: " <> show (paramVars lorenz))
  field <- compileField lorenz
  orbit <- integrate field
    { x: 1.0, y: 1.0, z: 1.0 }
    { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
    0.01
    5000
  let
    maxZ = foldl (\m st -> max m (fromMaybe 0.0 (st Array.!! 2))) 0.0 orbit
    last = fromMaybe [] (orbit Array.!! (Array.length orbit - 1))
  log ("steps:      " <> show (Array.length orbit))
  log ("last state: " <> show last)
  log ("maxZ:       " <> show maxZ)
  log ("orbit sane (40 < maxZ < 55, cf. lorenz-leaf 47.83): "
    <> show (40.0 < maxZ && maxZ < 55.0))
