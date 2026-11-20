-- | One test asteroid in the planar circular restricted three-body problem,
-- | Sun and Jupiter, as a `Data.Simulation.Spec`: started at perihelion of
-- | a Kepler orbit (a, e), run until it escapes, meets Jupiter, or outlives
-- | the horizon.
-- |
-- | `chaos` is the same orbit carrying a tangent vector, for the atlas's
-- | chaos indicator: how fast two orbits that start a hair apart separate.
-- |
-- | These are the descriptions the service's sweep kernels are compiled from.
-- | `Data.Simulation` builds the Runge-Kutta step out of the rates below,
-- | and `Data.Simulation.Julia` hands that program to Julia. The arithmetic
-- | is spelled as `Atlas.Dynamics` spells it, operation for operation, so
-- | that the browser, which steps an orbit with `Atlas.Dynamics.rk4Step`,
-- | reproduces what the kernel computed to the last bit. The service checks
-- | that agreement when it starts.
module Atlas.Survival
  ( survival
  , chaos
  , inputs
  , verdict
  , chaosVerdict
  ) where

import Prelude

import Atlas.Dynamics (stepsPerPeriod)
import Data.Number (ln10, pi, round)
import Data.NumExpr (NumExpr, divide, ifGreater, larger, logE, num, pow, sqrtE, var)
import Data.Simulation (Spec, Variable)
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

-- | What the atlas paints with the chaos indicator on. A lost orbit is
-- | painted as before. A survivor is painted 1 plus its indicator, capped
-- | at 8 and scaled to 0..1, to four places: 1 is as regular as an orbit
-- | gets and 2 is chaotic. `maxLog` is the final value of the variable of
-- | that name in `chaos`.
chaosVerdict :: Number -> { time :: Number, event :: Int, maxLog :: Number } -> Number
chaosVerdict horizonPeriods run =
  if run.event < 0 then 1.0 + round (min run.maxLog 8.0 / 8.0 * 10000.0) / 10000.0
  else verdict horizonPeriods { time: run.time, event: run.event }

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
  , state: orbit
  , held: []
  , updates: []
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
  rp = var "rp"
  x0 = var "x0"

-- | The survival run with a tangent vector (px, py, pvx, pvy) carried along
-- | the orbit by the linearised equations of motion. Its length grows
-- | exponentially on a chaotic orbit and slowly on a regular one.
-- |
-- | Every 16 steps the run looks at the length. `maxLog` remembers the
-- | largest log10 of it seen so far (the Fast Lyapunov Indicator). When the
-- | length passes 1e12 the vector is scaled back to length 1, before it
-- | overflows, and `accLog` keeps the log10 that was divided out. Those two
-- | are held variables: no differential equation moves them.
chaos :: Spec
chaos = survival
  { state = orbit <>
      [ { name: "px", initial: half, rate: pvx }
      , { name: "py", initial: half, rate: pvy }
      , { name: "pvx", initial: half, rate: uxx * px + uxy * py + num 2.0 * pvy }
      , { name: "pvy", initial: half, rate: uxy * px + uyy * py - num 2.0 * pvx }
      ]
  , held =
      [ { name: "accLog", initial: zero }
      , { name: "maxLog", initial: zero }
      ]
  , updates =
      [ { every: 16
        , set:
            [ Tuple "maxLog" (larger grown (var "maxLog"))
            , Tuple "accLog" (ifGreater norm tooLong grown (var "accLog"))
            , Tuple "px" (ifGreater norm tooLong (divide px norm) px)
            , Tuple "py" (ifGreater norm tooLong (divide py norm) py)
            , Tuple "pvx" (ifGreater norm tooLong (divide pvx norm) pvx)
            , Tuple "pvy" (ifGreater norm tooLong (divide pvy norm) pvy)
            ]
        }
      ]
  }
  where
  half = num 0.5
  px = var "px"
  py = var "py"
  pvx = var "pvx"
  pvy = var "pvy"

  -- The second derivatives of the effective potential.
  m1 = one - mu
  r15 = r1c * r1sq
  r25 = r2c * r2sq
  uxx = one - divide m1 r1c + divide (num 3.0 * m1 * dx1 * dx1) r15 - divide mu r2c + divide (num 3.0 * mu * dx2 * dx2) r25
  uyy = one - divide m1 r1c + divide (num 3.0 * m1 * y * y) r15 - divide mu r2c + divide (num 3.0 * mu * y * y) r25
  uxy = divide (num 3.0 * m1 * dx1 * y) r15 + divide (num 3.0 * mu * dx2 * y) r25

  norm = sqrtE (px * px + py * py + pvx * pvx + pvy * pvy)
  tooLong = num 1.0e12
  -- log10, from the natural logarithm every runtime has.
  grown = var "accLog" + divide (logE norm) (num ln10)

-- The four variables of the orbit itself, in the rotating frame.
orbit :: Array Variable
orbit =
  [ { name: "x", initial: var "x0", rate: vx }
  , { name: "y", initial: zero, rate: vy }
  , { name: "vx", initial: zero, rate: ax }
  , { name: "vy", initial: var "vy0", rate: ay }
  ]

mu :: NumExpr
mu = var "mu"

x :: NumExpr
x = var "x"

y :: NumExpr
y = var "y"

vx :: NumExpr
vx = var "vx"

vy :: NumExpr
vy = var "vy"

-- Offsets from the Sun and from Jupiter, and the distances to each,
-- squared and cubed.
dx1 :: NumExpr
dx1 = x + mu

dx2 :: NumExpr
dx2 = x - one + mu

r1sq :: NumExpr
r1sq = dx1 * dx1 + y * y

r2sq :: NumExpr
r2sq = dx2 * dx2 + y * y

r1c :: NumExpr
r1c = r1sq * sqrtE r1sq

r2c :: NumExpr
r2c = r2sq * sqrtE r2sq

ax :: NumExpr
ax = x + num 2.0 * vy - divide ((one - mu) * dx1) r1c - divide (mu * dx2) r2c

ay :: NumExpr
ay = y - num 2.0 * vx - divide ((one - mu) * y) r1c - divide (mu * y) r2c
