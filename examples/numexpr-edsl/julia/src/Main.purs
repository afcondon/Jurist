-- | Tier-2 demo, four increments:
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
-- |  4. lift again to a `DAESpec` — a double pendulum in Cartesian coordinates,
-- |     a differential-*algebraic* system (rod tensions are algebraic variables
-- |     closed by rigidity constraints). MTK produces an index-1 DAE; an
-- |     implicit stiff solver holds the constraints (rods stay rigid to ~1e-8)
-- |     through fully chaotic motion — something no plain ODE integrator, and no
-- |     `scipy.solve_ivp`, can do. The trajectory is written to JSON for the
-- |     Hylograph frontend.
module Main where

import Prelude

import Data.Array (concat, elemIndex, index, length, range, take, zipWith, (!!)) as Array
import Data.Foldable (foldl, sum)
import Data.Int (toNumber)
import Data.Maybe (fromMaybe)
import Data.Ord (abs)
import Data.DAESystem (DAESpec, algVars, buildDAEField, daeSystem, dumpFramesJSON, sampleColumns, simplifiedEquationsSource, solveDAE, stateVars) as DAE
import Data.MTKSystem (buildField, equationsSource, finalState, jacobianSource, maxComponent, solve) as MTK
import Data.NumExpr (NumExpr, divide, eval, num, render, sinE, var)
import Data.NumExpr.Julia (compile, evalBatch)
import Data.SystemSpec (SystemSpec, integratePure, paramVars, stateVars, system)
import Data.SystemSpec.Julia (compileField, integrate)
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

-- ── Increment 4: a differential-algebraic system (double pendulum) ──────────

-- Differential state: two bob positions and their velocities (Cartesian).
type DPState =
  ( x1 :: NumExpr, y1 :: NumExpr, x2 :: NumExpr, y2 :: NumExpr
  , u1 :: NumExpr, v1 :: NumExpr, u2 :: NumExpr, v2 :: NumExpr
  )

-- Algebraic variables: the two rod tensions (no time derivative).
type DPAlg = ( t1 :: NumExpr, t2 :: NumExpr )

type DPParams =
  ( g :: NumExpr, m1 :: NumExpr, m2 :: NumExpr, l1 :: NumExpr, l2 :: NumExpr )

-- The Cartesian accelerations in terms of the (algebraic) tensions — shared
-- between the differential RHS and the closing constraints, so they are written
-- once. Rod 1 pulls bob 1 toward the origin (`-t1·p1`) while rod 2 pulls it
-- toward bob 2 (`+t2·(p2−p1)`); rod 2 pulls bob 2 toward bob 1. Gravity acts on
-- the y components.
accels
  :: Record DPState
  -> Record DPAlg
  -> Record DPParams
  -> { ax1 :: NumExpr, ay1 :: NumExpr, ax2 :: NumExpr, ay2 :: NumExpr }
accels s a p =
  { ax1: (negate a.t1 * s.x1 + a.t2 * (s.x2 - s.x1)) `divide` p.m1
  , ay1: ((negate a.t1 * s.y1 + a.t2 * (s.y2 - s.y1)) `divide` p.m1) - p.g
  , ax2: (negate a.t2 * (s.x2 - s.x1)) `divide` p.m2
  , ay2: ((negate a.t2 * (s.y2 - s.y1)) `divide` p.m2) - p.g
  }

-- | The double pendulum as an index-1 DAE. The first lambda is the differential
-- | part (positions integrate the velocities; velocities integrate the
-- | accelerations). The second gives one *acceleration-level* rigidity
-- | constraint per tension: differentiating `|pᵢ|² = Lᵢ²` twice yields a
-- | relation linear in the tensions and nonsingular everywhere (it divides by
-- | `|pᵢ|² = Lᵢ² ≠ 0`, unlike a single-coordinate chart, which is singular when
-- | the rod is vertical). MTK solves the 2×2 tension system symbolically.
doublePendulum :: DAE.DAESpec DPState DPAlg DPParams
doublePendulum =
  DAE.daeSystem
    ( \s a p ->
        let ac = accels s a p
        in
          { x1: s.u1, y1: s.v1, x2: s.u2, y2: s.v2
          , u1: ac.ax1, v1: ac.ay1, u2: ac.ax2, v2: ac.ay2
          }
    )
    ( \s a p ->
        let ac = accels s a p
        in
          { t1: s.u1 * s.u1 + s.v1 * s.v1 + s.x1 * ac.ax1 + s.y1 * ac.ay1
          , t2: (s.u2 - s.u1) * (s.u2 - s.u1) + (s.v2 - s.v1) * (s.v2 - s.v1)
              + (s.x2 - s.x1) * (ac.ax2 - ac.ax1)
              + (s.y2 - s.y1) * (ac.ay2 - ac.ay1)
          }
    )

-- Number of animation frames written to JSON for the Hylograph frontend.
nFrames :: Int
nFrames = 1200

trajectoryPath :: String
trajectoryPath = "double-pendulum.json"

-- |x1²+y1²−L1²| and |(x2−x1)²+(y2−y1)²−L2²| for a sampled [x1,y1,x2,y2] frame
-- (L1 = L2 = 1) — how far the rigid rods have drifted, computed back in PS.
rodDrift :: Array Number -> Number
rodDrift frame = max r1 r2
  where
  g i = fromMaybe 0.0 (frame Array.!! i)
  x1 = g 0
  y1 = g 1
  x2 = g 2
  y2 = g 3
  r1 = abs (x1 * x1 + y1 * y1 - 1.0)
  r2 = abs ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) - 1.0)

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

  log "\n== increment 2 (cross-check): the SAME SystemSpec, a pure-PureScript RK4 =="
  -- The develop-anywhere denotation: no FFI, runs on any backend. One
  -- description (`lorenz`), two denotations — Julia `integrate` and pure
  -- `integratePure` — cross-checked, exactly as increment 1 does for NumExpr.
  let
    orbitPure = integratePure lorenz
      { x: 1.0, y: 1.0, z: 1.0 }
      { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
      0.01
      5000
    maxZpure = foldl (\m st -> max m (fromMaybe 0.0 (st Array.!! 2))) 0.0 orbitPure
    identical = orbit == orbitPure
    -- Short-horizon numerical agreement: Lorenz is chaotic, so any ULP
    -- difference amplifies over 5000 steps; the first 200 steps test that the
    -- two denotations *compute the same thing* before chaos dominates.
    diffs = Array.concat
      ( Array.zipWith (\a b -> Array.zipWith (\x y -> abs (x - y)) a b)
          (Array.take 200 orbit)
          (Array.take 200 orbitPure)
      )
    maxDiff200 = foldl max 0.0 diffs
  log ("maxZ (pure-PS RK4):                   " <> show maxZpure)
  log ("byte-identical to Julia over 5000 steps: " <> show identical)
  log ("max abs diff over first 200 steps:       " <> show maxDiff200)

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

  log "\n== increment 4: double pendulum as an index-1 DAE (ModelingToolkit) =="
  log ("differential state: " <> show (DAE.stateVars doublePendulum))
  log ("algebraic vars (rod tensions): " <> show (DAE.algVars doublePendulum))
  dpField <- DAE.buildDAEField doublePendulum
  dpEqs <- DAE.simplifiedEquationsSource dpField
  log "simplified DAE (differential eqs + algebraic constraints closing the tensions):"
  log dpEqs
  -- Both rods horizontal, at rest — a high-energy, fully chaotic start.
  dpSol <- DAE.solveDAE dpField
    { x1: 1.0, y1: 0.0, x2: 2.0, y2: 0.0, u1: 0.0, v1: 0.0, u2: 0.0, v2: 0.0 }
    { t1: 0.0, t2: 0.0 }
    { g: 9.81, m1: 1.0, m2: 1.0, l1: 1.0, l2: 1.0 }
    0.0
    20.0
  -- The result crosses back to PS: check the rigid rods stayed rigid.
  checkFrames <- DAE.sampleColumns dpSol [ "x1", "y1", "x2", "y2" ]
    [ 0.0, 5.0, 10.0, 15.0, 20.0 ]
  let drift = foldl max 0.0 (map rodDrift checkFrames)
  log ("max rod-length drift over the run: " <> show drift)
  log ("constraints maintained through chaos (drift < 1e-6): " <> show (drift < 1.0e-6))
  -- Write the full animation trajectory (Julia-side) for the Hylograph frontend.
  let
    frameTimes =
      map (\i -> 20.0 * toNumber i / toNumber (nFrames - 1)) (Array.range 0 (nFrames - 1))
  DAE.dumpFramesJSON dpSol [ "x1", "y1", "x2", "y2" ] frameTimes
    "\"l1\":1.0,\"l2\":1.0,\"t0\":0.0,\"t1\":20.0"
    trajectoryPath
  log ("wrote " <> show (Array.length frameTimes) <> " frames to " <> trajectoryPath)
