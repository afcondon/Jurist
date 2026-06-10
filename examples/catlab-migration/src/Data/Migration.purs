-- | Tier-3 (Catlab / ACSets): **functorial data migration**. The other ACSet
-- | superpower beside homomorphism search — transform structured data *along a
-- | schema mapping*, with categorical guarantees. Here a Δ (pullback) migration
-- | aggregates a function-level call graph **up** to a module dependency graph
-- | along the `in_mod` functor: every call `f → g` becomes a module edge
-- | `in_mod(f) → in_mod(g)`. Not a hand-written fold — a migration functor.
-- |
-- | The result is a plain graph — exactly the shape Hylograph would lay out and
-- | render. So this both demonstrates migration and produces a Hylograph-shaped
-- | artifact: describe the fine structure in PureScript, let Catlab derive the
-- | coarse view, bring it back to draw.
module Data.Migration
  ( Edge
  , Func
  , CodeGraph
  , moduleGraph
  , writeText
  ) where

import Prelude

import Data.Array (length)
import Effect (Effect)

type Edge = { from :: Int, to :: Int }
type Func = { name :: String, inMod :: Int }
type CodeGraph = { modules :: Array String, funcs :: Array Func, calls :: Array Edge }

foreign import moduleGraphJ
  :: Int -> Array Int -> Array Int -> Array Int -> Effect (Array (Array Int))

foreign import writeTextJ :: String -> String -> Effect Unit

-- | Migrate the call graph up to the module graph (Δ along `in_mod`). Returns one
-- | `[srcMod, tgtMod]` per call (0-based) — a multigraph; aggregate for coupling
-- | weights and intra-module self-loops.
moduleGraph :: CodeGraph -> Effect (Array (Array Int))
moduleGraph g =
  moduleGraphJ (length g.modules) (map _.inMod g.funcs)
    (map _.from g.calls) (map _.to g.calls)

writeText :: String -> String -> Effect Unit
writeText = writeTextJ
