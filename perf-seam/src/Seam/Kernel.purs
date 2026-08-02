-- | The seam under test: **one real library call per invocation**.
-- |
-- | Everything else in this repo measures either meaning (the differential
-- | corpus) or PureScript-against-itself (the canary). This module measures
-- | the thing the backends actually exist for — reaching a foreign library —
-- | and it does so at the boundary the seam rule puts it at: PureScript owns
-- | the loop, the library is called once per item.
-- |
-- | That is not an arbitrary choice. `Grid.Contingency` calls pandapower 42
-- | times because the N-1 loop is the analysis and belongs in PureScript; the
-- | alternative, handing the whole sweep to the foreign side, moves our
-- | algorithm into the foreign file and is exactly what the seam rule
-- | forbids. So the interesting question is not "can a chunky seam be cheap"
-- | — it obviously can — but **how much work a call has to do before the
-- | crossing stops mattering.**
module Seam.Kernel
  ( nowNs
  , flushOut
  , foreignNs
  , resetForeignNs
  , solveOrbit
  , solveOrbitSamples
  , workLadder
  , payloadWork
  ) where

import Data.Unit (Unit)
import Effect (Effect)

-- | Monotonic clock in nanoseconds. `Number` is exact to 2^53 ns (~104 days),
-- | and sidesteps the Int-width question the backends disagree on.
foreign import nowNs :: Effect Number

-- | Some runtimes block-buffer redirected stdout — Julia does — so without
-- | this a long run yields nothing at all until it ends, and a lane that dies
-- | on a timeout dies with no information about which row hung.
foreign import flushOut :: Effect Unit

-- | Nanoseconds accumulated INSIDE the library, summed across calls by the
-- | foreign itself.
-- |
-- | This is what makes `structural distortion` computable without a profiler:
-- | `poly_foreign / native_foreign` compares time spent inside the library
-- | called from here against time spent in the SAME library called from a
-- | plain program in that language. Total minus foreign is then the seam plus
-- | our own loop — the part that is ours to be charged for.
foreign import foreignNs :: Effect Number

foreign import resetForeignNs :: Effect Unit

-- | Solve ONE orbit through the runtime's own ODE library — an adaptive
-- | high-order integrator with root-found escape and close-encounter events —
-- | and return the survival verdict.
-- |
-- | This module is BYTE-IDENTICAL across the backends that can host the same
-- | physics (OrdinaryDiffEq.jl on Jurist, scipy.integrate on Pythia), exactly
-- | as the canary's shapes and the differential corpus are. Only `ffi-*/` and
-- | the native arm differ, so a difference in the numbers is a difference in
-- | the seam and not in what was asked of it.
-- |
-- | Deliberately the THINNEST possible payload: four `Number`s in, one out.
-- | Anything the crossing costs here is call overhead, not marshalling, which
-- | is what makes `solveOrbitSamples` the useful contrast rather than a
-- | duplicate.
-- |
-- | `horizonPeriods` is the work dial. It sets how long the solver integrates,
-- | so it moves work-per-call across roughly two orders of magnitude without
-- | changing the shape of anything else.
foreign import solveOrbit
  :: Number -- ^ mu
  -> Number -- ^ semi-major axis
  -> Number -- ^ eccentricity
  -> Number -- ^ horizon, in Jupiter periods
  -> Number

-- | The same solve, returning `nSamples` points of the trajectory instead of
-- | one verdict.
-- |
-- | Same call count, same library, same work — only the payload grows. The
-- | difference between this and `solveOrbit` at equal horizon is therefore
-- | marshalling cost per element, isolated from everything else.
foreign import solveOrbitSamples
  :: Number -- ^ mu
  -> Number -- ^ semi-major axis
  -> Number -- ^ eccentricity
  -> Number -- ^ horizon, in Jupiter periods
  -> Int -- ^ samples returned
  -> Array Number

-- | The work-per-call ladder, in this problem's own units, **supplied by the
-- | backend rather than fixed here**.
-- |
-- | The axis under test is microseconds of library work bought per crossing,
-- | and the horizon is only the dial that moves it. Different runtimes need
-- | very different dial settings to cover the same range of microseconds:
-- | measured 2026-08-02, one 150-period solve costs ~10 ms through
-- | OrdinaryDiffEq and ~497 ms through scipy, a factor of fifty. Fixing the
-- | ladder in this module would either take fifty minutes on the slow backend
-- | or measure a fifty-times-narrower range on the fast one, and neither is a
-- | comparison.
-- |
-- | So each backend's FFI calibrates its own ladder to span the SAME
-- | microsecond range, the shared PureScript stays byte-identical, and the
-- | calibration becomes an explicit documented decision instead of an
-- | accident of whoever wrote the array.
foreign import workLadder :: Array Number

-- | The work setting the payload axis holds fixed while the payload varies.
-- | Backend-supplied for the same reason.
foreign import payloadWork :: Number
