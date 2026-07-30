-- | The runtime-advantage measurement.
-- |
-- | The exhibit's claim is that this computation is dramatically better served
-- | by Julia than by Node. That is testable rather than assertable, because
-- | `Atlas.Dynamics` is FFI-free: the *same source* compiles to both runtimes.
-- | Whatever the ratio turns out to be, it is a property of the runtimes and
-- | not of two different programs.
-- |
-- | No clock is read here, which keeps the module FFI-free and therefore
-- | compilable everywhere. Timing is external, and startup cost — Julia's JIT
-- | is seconds, Node's is milliseconds — is cancelled by running two sizes and
-- | taking the difference:
-- |
-- |     work(2N) - work(N)  =  the marginal cost of N steps, startup removed
-- |
-- | The checksum exists so neither runtime can win by skipping the work: both
-- | must print the same number, and `Atlas.Dynamics` is bit-exact across them.
module Atlas.Bench
  ( benchSteps
  , smallSize
  , largeSize
  ) where

import Prelude

import Atlas.Dynamics (State, initialState, integrateSteps)

mu :: Number
mu = 9.54e-4

dt :: Number
dt = 1.0e-3

start :: State
start = initialState mu 0.4806 0.12

smallSize :: Int
smallSize = 2000000

largeSize :: Int
largeSize = 4000000

-- | Integrate `n` fixed steps and fold the final state into one number. The
-- | fold is trivial next to the integration, so the figure is the integrator.
benchSteps :: Int -> Number
benchSteps n =
  let
    s = integrateSteps mu dt n start
  in
    s.x + s.y + s.vx + s.vy
