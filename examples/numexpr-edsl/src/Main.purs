-- | Tier-2 demo, three increments:
-- |  1. stage a single `NumExpr` across the seam, compile it to a native Julia
-- |     function, and check it against the pure PS interpreter (faithful
-- |     staging — both run on Julia, so any mismatch is a staging bug);
-- |  2. lift to a row-typed `SystemSpec` (Lorenz), compile its vector field and
-- |     integrate it with a hand-written native RK4, validating the orbit
-- |     against the independent `examples/lorenz-leaf` (maxZ ≈ 47.83);
-- |  3. denote the *same* `SystemSpec` into ModelingToolkit — symbolic
-- |     `ODESystem`, analytic Jacobian, stiff-aware adaptive solve — and show
-- |     two things RK4 can't: the derived Jacobian, and a genuinely stiff system
-- |     (Robertson) solved cleanly.
module Main where

import Prelude

import Data.Array (elemIndex, index, length, (!!)) as Array
import Data.Foldable (foldl, sum)
import Data.Maybe (fromMaybe)
import Data.Ord (abs)
import Data.MTKSystem (buildField, equationsSource, finalState, jacobianSource, maxComponent, solve) as MTK
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

-- ── Increment 2 & 3: a row-typed dynamical system ───────────────────────────

lorenz
  :: SystemSpec
       ( x :: NumExpr, y :: NumExpr, z :: NumExpr )
       ( sigma :: NumExpr, rho :: NumExpr, beta :: NumExpr )
lorenz = system \s p ->
  { x: p.sigma * (s.y - s.x)
  , y: s.x * (p.rho - s.z) - s.y
  , z: s.x * s.y - p.beta * s.z
  }

-- | The Robertson stiff chemical kinetics problem — three reactions spanning
-- | many orders of magnitude in rate (`a` slow, `b` very fast). A fixed-step
-- | explicit RK4 needs absurdly small steps to stay stable; a stiff solver with
-- | the analytic Jacobian (what MTK derives below) handles it directly.
robertson
  :: SystemSpec
       ( y1 :: NumExpr, y2 :: NumExpr, y3 :: NumExpr )
       ( a :: NumExpr, b :: NumExpr, c :: NumExpr )
robertson = system \s p ->
  { y1: num 0.0 - p.a * s.y1 + p.c * s.y2 * s.y3
  , y2: p.a * s.y1 - p.c * s.y2 * s.y3 - p.b * s.y2 * s.y2
  , y3: p.b * s.y2 * s.y2
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

  log "\n== increment 2: Lorenz via hand-written RK4 =="
  log ("state vars: " <> show (stateVars lorenz))
  log ("param vars: " <> show (paramVars lorenz))
  field <- compileField lorenz
  orbit <- integrate field
    { x: 1.0, y: 1.0, z: 1.0 }
    { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
    0.01
    5000
  let
    maxZrk4 = foldl (\m st -> max m (fromMaybe 0.0 (st Array.!! 2))) 0.0 orbit
  log ("steps:      " <> show (Array.length orbit))
  log ("maxZ (RK4): " <> show maxZrk4)

  log "\n== increment 3: same Lorenz, denoted into ModelingToolkit =="
  mtkLorenz <- MTK.buildField lorenz
  eqSrc <- MTK.equationsSource mtkLorenz
  jacSrc <- MTK.jacobianSource mtkLorenz
  log "simplified equations (symbolic ODESystem):"
  log eqSrc
  log "analytic Jacobian (∂f/∂state) — derived by MTK, never written in PS:"
  log jacSrc
  solLorenz <- MTK.solve mtkLorenz
    { x: 1.0, y: 1.0, z: 1.0 }
    { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
    0.0
    50.0
  maxZmtk <- MTK.maxComponent solLorenz 2
  log ("maxZ (default adaptive solver, auto-switches to stiff): " <> show maxZmtk)
  log ("envelope agrees with RK4 / lorenz-leaf (40 < maxZ < 55, chaotic so not bit-identical): "
    <> show (40.0 < maxZmtk && maxZmtk < 55.0))

  log "\n== increment 3 (stiff): Robertson, only solvable with a stiff method =="
  mtkRob <- MTK.buildField robertson
  robJac <- MTK.jacobianSource mtkRob
  log "analytic Jacobian:"
  log robJac
  solRob <- MTK.solve mtkRob
    { y1: 1.0, y2: 0.0, y3: 0.0 }
    { a: 0.04, b: 3.0e7, c: 1.0e4 }
    0.0
    10000.0
  finalRob <- MTK.finalState solRob
  let conserved = sum finalRob
  log ("final state @ t=1e4: " <> show finalRob)
  log ("mass conserved (Σy ≈ 1.0): " <> show conserved)
  log ("stiff solve sane (|Σy − 1| < 1e-4): " <> show (abs (conserved - 1.0) < 1.0e-4))
