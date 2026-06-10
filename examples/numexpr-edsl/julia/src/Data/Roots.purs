-- | Tier-2, rigorous root finding: hand a single-variable `NumExpr` across the
-- | seam and get back a **proof** about its roots — not "Newton converged to a
-- | number", but `IntervalRootFinding`'s guaranteed enclosures: each root
-- | bracketed in a tiny interval and *certified unique*, with the certainty that
-- | **no other roots exist** in the search box (or none at all). Validated
-- | numerics: the answer holds despite floating point.
-- |
-- | This is squarely Julia-exclusive — `scipy`/JS root finders give you a number
-- | and a prayer; there's no rigorous interval-arithmetic stack to hand a typed
-- | description to. The same `NumExpr` eDSL that crosses the seam for staging and
-- | differentiation crosses here too (the increment-1 currency).
module Data.Roots
  ( provenRoots
  , sampleCurve
  ) where

import Prelude

import Data.NumExpr (NumExpr)
import Data.NumExpr.Julia (JExpr, toJExpr)
import Effect (Effect)

-- Each root comes back as `[lo, hi, uniqueFlag]` — the proven enclosure plus
-- 1.0 if IntervalRootFinding certified it unique, 0.0 if only :unknown.
foreign import provenRootsJ :: String -> Number -> Number -> JExpr -> Effect (Array (Array Number))

-- Each sample is `[x, f(x)]` — for drawing the curve the roots sit on.
foreign import sampleCurveJ :: String -> Number -> Number -> Int -> JExpr -> Effect (Array (Array Number))

-- | Rigorously find every root of `f` in `[lo, hi]` (in the named variable),
-- | each returned as `[enclosureLo, enclosureHi, unique]`. An empty result is
-- | itself a proof: no roots exist in the box.
provenRoots :: String -> Number -> Number -> NumExpr -> Effect (Array (Array Number))
provenRoots v lo hi e = provenRootsJ v lo hi (toJExpr e)

-- | Sample `f` at `n + 1` evenly-spaced points across `[lo, hi]`, as `[x, f x]`.
sampleCurve :: String -> Number -> Number -> Int -> NumExpr -> Effect (Array (Array Number))
sampleCurve v lo hi n e = sampleCurveJ v lo hi n (toJExpr e)
