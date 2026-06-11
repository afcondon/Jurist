-- | The same program, three runtimes. This module is byte-identical in the
-- | node/, beam/ and julia/ workspaces; what differs is which `Data.Verbs`
-- | it compiles against. On Node and the BEAM the production verbs answer
-- | with a typed `Deferred` placeholder — the program still type-checks,
-- | runs, and renders honestly; no stub masquerades as data. On Julia the
-- | same calls answer `Computed`, with the real gradient, the real proven
-- | enclosures, the real symbolic Jacobian, the real DAE solve, the real
-- | certified optimum (ADR-0007: one description, a hierarchy of
-- | interpreters).
module VerbsDemo (run) where

import Prelude

import Data.Answer (describe)
import Data.DAESpec (DAESpec, daeSystem)
import Data.NumExpr (NumExpr, logE, num, pow, sinE, var)
import Data.SystemSpec (SystemSpec, system)
import Data.Verbs (gradientLatex, jacobianSource, knapsack, provenRoots, solveDAE)
import Effect (Effect)
import Effect.Console (log)

-- The differentiation showcase: 10x² − xy + sin y + log x.
showcase :: NumExpr
showcase =
  num 10.0 * pow (var "x") (num 2.0)
    - var "x" * var "y"
    + sinE (var "y")
    + logE (var "x")

-- The Lorenz system, described as a row-typed value — the same description the
-- main demos integrate; here it feeds the symbolic-Jacobian verb.
lorenz
  :: SystemSpec
       ( x :: NumExpr, y :: NumExpr, z :: NumExpr )
       ( sigma :: NumExpr, rho :: NumExpr, beta :: NumExpr )
lorenz = system \s p ->
  { x: p.sigma * (s.y - s.x)
  , y: s.x * (p.rho - s.z) - s.y
  , z: s.x * s.y - p.beta * s.z
  }

-- A pendulum in Cartesian coordinates as an index-1 DAE: positions and
-- velocities are differential state; the rod tension `lam` is algebraic,
-- closed by the acceleration-level rigidity constraint (|p|² = 1
-- differentiated twice). Mass and rod length are 1.
pendulum
  :: DAESpec
       ( x :: NumExpr, y :: NumExpr, u :: NumExpr, v :: NumExpr )
       ( lam :: NumExpr )
       ( g :: NumExpr )
pendulum =
  daeSystem
    ( \s a p ->
        { x: s.u, y: s.v, u: negate a.lam * s.x, v: negate a.lam * s.y - p.g }
    )
    ( \s a p ->
        { lam: s.u * s.u + s.v * s.v
            + s.x * (negate a.lam * s.x)
            + s.y * (negate a.lam * s.y - p.g)
        }
    )

run :: Effect Unit
run = do
  log "\n== the verb surface: same program, this runtime's answers =="
  grad <- gradientLatex [ "x", "y" ] [ "x", "y" ] showcase
  log ("∇f:       " <> describe show grad)
  let x = var "x"
  roots <- provenRoots "x" (-3.0) 3.0 (x * x * x - num 2.0 * x - num 5.0)
  log ("roots:    " <> describe show roots)
  jac <- jacobianSource lorenz
  log ("Jacobian: " <> describe identity jac)
  -- Released horizontal, at rest; two seconds of swing.
  final <- solveDAE pendulum
    { x: 1.0, y: 0.0, u: 0.0, v: 0.0 }
    { lam: 0.0 }
    { g: 9.81 }
    0.0
    2.0
  log ("pendulum DAE, state [u,v,x,y] at t=2: " <> describe show final)
  best <- knapsack [ 6.0, 5.0, 5.0, 7.0 ] [ 12.0, 9.0, 9.0, 8.0 ] 10.0
  log ("knapsack [obj,gap,proven,mask…]: " <> describe show best)
