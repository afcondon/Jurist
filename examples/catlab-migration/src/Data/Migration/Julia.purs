-- | The **Julia denotation** of the migration surface: the typed code graph
-- | (from core's `Data.Migration`) crosses the seam as plain arrays; Catlab
-- | builds it as an ACSet and migrates it along the `in_mod` functor — a Δ
-- | migration with categorical guarantees, not a hand-written fold.
module Data.Migration.Julia
  ( moduleGraph
  , writeText
  ) where

import Prelude

import Data.Array (length)
import Data.Migration (CodeGraph)
import Effect (Effect)

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
