-- | One test asteroid in the planar circular restricted three-body problem,
-- | Sun and Jupiter, as a `Data.Simulation.Spec`: started at perihelion of
-- | a Kepler orbit (a, e), run until it escapes, meets Jupiter, or outlives
-- | the horizon.
-- |
-- | This is the description the service's sweep kernel is compiled from.
-- | `Data.Simulation` builds the Runge-Kutta step out of the rates below,
-- | and `Data.Simulation.Julia` hands that program to Julia. The arithmetic
-- | is spelled as `Atlas.Dynamics` spells it, operation for operation, so
-- | that the browser, which steps an orbit with `Atlas.Dynamics.rk4Step`,
-- | reproduces what the kernel computed to the last bit. The service checks
-- | that agreement when it starts.
module Atlas.Survival
  ( survival
  , inputs
  , verdict
  ) where

import Prelude

import Atlas.Dynamics (stepsPerPeriod)
import Data.Number (pi, round)
import Data.NumExpr (NumExpr, divide, num, pow, sqrtE, var)
import Data.Simulation (Spec)
import Data.Tuple (Tuple(..))

-- | The inputs of one run, in the order `survival` takes them: semi-major
-- | axis in units of Jupiter's, eccentricity, the mass ratio, and the
-- | horizon in Jupiter periods.
inputs :: { a :: Number, e :: Number, mu :: Number, horizonPeriods :: Number } -> Array Number
inputs r = [ r.a, r.e, r.mu, r.horizonPeriods, stepsPerPeriod ]

-- | The number the atlas paints for one orbit: 1 if it outlived the
-- | horizon, otherwise the fraction of the horizon it lasted, to four
-- | places. `event` is the index of the event that ended the run, or
-- | negative if none did.
verdict :: Number -> { time :: Number, event :: Int } -> Number
verdict horizonPeriods run =
  if run.event < 0 then 1.0
  else round (run.time / (horizonPeriods * 2.0 * pi) * 10000.0) / 10000.0

survival :: Spec
survival =
  { inputs: [ "a", "e", "mu", "periods", "stepsPerPeriod" ]
  , derived:
      [ Tuple "rp" (a * (one - e))
      , Tuple "x0" (rp - mu)
      , Tuple "vy0" (sqrtE (divide ((one - mu) * (one + e)) rp) - x0)
      -- Jupiter's Hill radius and the escape distance, both squared.
      , Tuple "rHillSq" (pow (divide mu (num 3.0)) (divide (num 2.0) (num 3.0)))
      , Tuple "rEscSq" (num 9.0)
      ]
  , state:
      [ { name: "x", initial: x0, rate: vx }
      , { name: "y", initial: zero, rate: vy }
      , { name: "vx", initial: zero, rate: ax }
      , { name: "vy", initial: var "vy0", rate: ay }
      ]
  -- a^1.5 is a * sqrt a: sqrt is correctly rounded on every runtime and
  -- pow is not, and one unit in the last place of the time step sends a
  -- chaotic orbit somewhere else.
  , timeStep: divide (num 2.0 * num pi * (a * sqrtE a)) (var "stepsPerPeriod")
  , horizon: var "periods" * num 2.0 * num pi
  , events:
      [ Tuple "escaped" (r1sq - var "rEscSq")
      , Tuple "met Jupiter" (var "rHillSq" - r2sq)
      ]
  }
  where
  a = var "a"
  e = var "e"
  mu = var "mu"
  rp = var "rp"
  x0 = var "x0"
  x = var "x"
  y = var "y"
  vx = var "vx"
  vy = var "vy"

  dx1 = x + mu
  dx2 = x - one + mu
  r1sq = dx1 * dx1 + y * y
  r2sq = dx2 * dx2 + y * y
  r1c = r1sq * sqrtE r1sq
  r2c = r2sq * sqrtE r2sq

  ax :: NumExpr
  ax = x + num 2.0 * vy - divide ((one - mu) * dx1) r1c - divide (mu * dx2) r2c

  ay :: NumExpr
  ay = y - num 2.0 * vx - divide ((one - mu) * y) r1c - divide (mu * y) r2c
