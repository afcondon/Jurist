-- | The **Julia denotation** of the homomorphism-search surface: the graph and
-- | motif descriptions (from core's `Data.Pattern`) cross the seam as plain
-- | arrays; Catlab builds both as ACSets and finds every occurrence of the
-- | pattern as the set of graph homomorphisms `pattern → graph` — the category
-- | doing the searching.
module Data.Pattern.Julia
  ( matches
  , writeText
  ) where

import Prelude

import Data.Array (length)
import Data.Pattern (Graph, Motif)
import Effect (Effect)

foreign import matchesJ
  :: Int
  -> Array Int
  -> Array Int
  -> Int
  -> Array Int
  -> Array Int
  -> Effect (Array (Array Int))

foreign import writeTextJ :: String -> String -> Effect Unit

-- | Every injective (`monic`) match of `pattern` in `graph`, each a map from the
-- | pattern's vertices to the graph's (0-based). Injective so a match uses
-- | distinct graph nodes — a genuine occurrence, not a degenerate collapse.
matches :: Graph -> Motif -> Effect (Array (Array Int))
matches g p =
  matchesJ (length g.nodes) (map _.from g.edges) (map _.to g.edges)
    p.nodes (map _.from p.edges) (map _.to p.edges)

writeText :: String -> String -> Effect Unit
writeText = writeTextJ
