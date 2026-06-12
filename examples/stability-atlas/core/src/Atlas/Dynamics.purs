-- | The planar circular restricted three-body problem (CR3BP) in the
-- | rotating frame, nondimensional units: total mass 1, Sun (mass 1−μ) at
-- | (−μ, 0), Jupiter (mass μ) at (1−μ, 0), Jupiter's period 2π. For the
-- | Sun–Jupiter system μ ≈ 9.54·10⁻⁴.
-- |
-- | This module is PURE PureScript — the develop-anywhere denotation. The
-- | service's threaded Julia sweep kernel mirrors `rk4Step` operation for
-- | operation (same IEEE doubles, same association), is cross-checked
-- | against it at boot, and the browser reuses this exact code for the
-- | honesty meter. One description; the production executor must agree
-- | with it to the last bit.
module Atlas.Dynamics
  ( State
  , initialState
  , rk4Step
  , integrateSteps
  , jacobi
  , asteroidPeriod
  , stepsPerPeriod
  , hillRadius
  , escapeRadius
  ) where

import Prelude

import Data.Number (pi, pow, sqrt)

-- | Position and velocity in the rotating frame.
type State = { x :: Number, y :: Number, vx :: Number, vy :: Number }

-- | Test asteroid at perihelion of a heliocentric Kepler orbit (a, e),
-- | started on the Sun–Jupiter line (perihelion at conjunction — a fixed
-- | phase choice, documented in the showcase plan), velocity converted to
-- | the rotating frame (v_rot = v_inertial − ω×r, ω = 1).
initialState :: Number -> Number -> Number -> State
initialState mu a e =
  let
    rp = a * (1.0 - e)
    x = rp - mu
    vIn = sqrt ((1.0 - mu) * (1.0 + e) / rp)
  in
    { x, y: 0.0, vx: 0.0, vy: vIn - x }

type Accel = { ax :: Number, ay :: Number }

accel :: Number -> Number -> Number -> Number -> Number -> Accel
accel mu x y vx vy =
  let
    dx1 = x + mu
    dx2 = x - 1.0 + mu
    r1sq = dx1 * dx1 + y * y
    r2sq = dx2 * dx2 + y * y
    r1c = r1sq * sqrt r1sq
    r2c = r2sq * sqrt r2sq
  in
    { ax: x + 2.0 * vy - (1.0 - mu) * dx1 / r1c - mu * dx2 / r2c
    , ay: y - 2.0 * vx - (1.0 - mu) * y / r1c - mu * y / r2c
    }

-- | One fixed-step RK4 step. The Julia kernel mirrors this exactly.
rk4Step :: Number -> Number -> State -> State
rk4Step mu dt s =
  let
    h = dt / 2.0
    a1 = accel mu s.x s.y s.vx s.vy
    k2x = s.vx + h * a1.ax
    k2y = s.vy + h * a1.ay
    a2 = accel mu (s.x + h * s.vx) (s.y + h * s.vy) k2x k2y
    k3x = s.vx + h * a2.ax
    k3y = s.vy + h * a2.ay
    a3 = accel mu (s.x + h * k2x) (s.y + h * k2y) k3x k3y
    k4x = s.vx + dt * a3.ax
    k4y = s.vy + dt * a3.ay
    a4 = accel mu (s.x + dt * k3x) (s.y + dt * k3y) k4x k4y
  in
    { x: s.x + dt / 6.0 * (s.vx + 2.0 * k2x + 2.0 * k3x + k4x)
    , y: s.y + dt / 6.0 * (s.vy + 2.0 * k2y + 2.0 * k3y + k4y)
    , vx: s.vx + dt / 6.0 * (a1.ax + 2.0 * a2.ax + 2.0 * a3.ax + a4.ax)
    , vy: s.vy + dt / 6.0 * (a1.ay + 2.0 * a2.ay + 2.0 * a3.ay + a4.ay)
    }

-- | Iterate `rk4Step` n times — the oracle integrator (tail recursive).
integrateSteps :: Number -> Number -> Int -> State -> State
integrateSteps mu dt = go
  where
  go :: Int -> State -> State
  go n s = case n of
    0 -> s
    _ -> go (n - 1) (rk4Step mu dt s)

-- | The Jacobi constant — the CR3BP's conserved quantity, and therefore
-- | the integrator-honesty metric: any drift is numerical error.
jacobi :: Number -> State -> Number
jacobi mu s =
  let
    dx1 = s.x + mu
    dx2 = s.x - 1.0 + mu
    r1 = sqrt (dx1 * dx1 + s.y * s.y)
    r2 = sqrt (dx2 * dx2 + s.y * s.y)
  in
    s.x * s.x + s.y * s.y
      + 2.0 * (1.0 - mu) / r1
      + 2.0 * mu / r2
      - s.vx * s.vx
      - s.vy * s.vy

-- | Kepler period of the asteroid's osculating orbit (Jupiter's is 2π).
asteroidPeriod :: Number -> Number
asteroidPeriod a = 2.0 * pi * pow a 1.5

-- | Fixed-step resolution: steps per asteroid period (accuracy/cost dial,
-- | shared by oracle and kernel so cross-checks line up). 120 is enough
-- | for survival verdicts — RK4 local error per period at 120 steps is
-- | far below the chaos being detected; the FLI layer can revisit.
stepsPerPeriod :: Number
stepsPerPeriod = 120.0

-- | Jupiter's Hill radius — the close-encounter threshold.
hillRadius :: Number -> Number
hillRadius mu = pow (mu / 3.0) (1.0 / 3.0)

-- | Heliocentric distance beyond which the asteroid counts as ejected.
escapeRadius :: Number
escapeRadius = 3.0
