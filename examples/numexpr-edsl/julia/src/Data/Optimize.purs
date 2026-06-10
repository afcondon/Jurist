-- | Tier-2, optimization: hand a typed problem across the seam and get back a
-- | **provably optimal** answer — not a heuristic, not "good enough", but the
-- | global optimum with a certificate (HiGHS's branch-and-bound closes the gap
-- | to 0). A 0/1 knapsack here, but the shape is general: a typed description of
-- | a mixed-integer program crosses once, Julia's `JuMP` builds and solves it,
-- | and the optimal selection + the proof of optimality come back.
-- |
-- | This is whole-engineering-artifact territory the JS/WASM backends have no
-- | answer to: there is no MILP solver to hand a model to. The companion
-- | `greedyValue` (pure PureScript) shows why it matters — the obvious greedy
-- | heuristic leaves value on the table; only the solver proves the true best.
module Data.Optimize
  ( knapsack
  , greedyValue
  ) where

import Prelude

import Data.Array (sortBy, range, length, index)
import Data.Foldable (foldl)
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Effect (Effect)

-- | Solve a 0/1 knapsack to **proven global optimality**. Given item weights and
-- | values and a capacity, returns a flat array
-- | `[objective, relativeGap, optimalFlag, chosen₁, …, chosenₙ]` where
-- | `optimalFlag` is 1.0 iff HiGHS certified the solution optimal and each
-- | `chosenᵢ` is 1.0/0.0.
foreign import knapsackJ :: Array Number -> Array Number -> Number -> Effect (Array Number)

knapsack :: Array Number -> Array Number -> Number -> Effect (Array Number)
knapsack = knapsackJ

-- | The value the **greedy** heuristic achieves: take items by descending
-- | value-to-weight ratio, adding each that still fits. Pure PureScript — runs
-- | anywhere, needs no solver. It is the baseline the MILP beats: greedy is fast
-- | but can be arbitrarily far from optimal (it commits to a shiny high-ratio
-- | item that then blocks a better combination).
greedyValue :: Array Number -> Array Number -> Number -> { value :: Number, mask :: Array Number }
greedyValue weights values cap =
  let
    n = length weights
    idxs = range 0 (n - 1)
    ratio i = at values i / at weights i
    ordered = sortBy (comparing (\i -> negate (ratio i))) idxs
    step acc i =
      if acc.used + at weights i <= cap then
        { used: acc.used + at weights i
        , value: acc.value + at values i
        , taken: acc.taken <> [ i ]
        }
      else acc
    res = foldl step { used: 0.0, value: 0.0, taken: [] } ordered
    mask = map (\i -> if elem' i res.taken then 1.0 else 0.0) idxs
  in
    { value: res.value, mask }
  where
  at xs i = fromMaybe 0.0 (index xs i)
  elem' i = foldl (\acc j -> acc || i == j) false
