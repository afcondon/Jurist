-- | Tier-3 (Catlab / ACSets): structural pattern-finding by **homomorphism
-- | search**. A graph and a *pattern* are both ACSets; Catlab finds every
-- | occurrence of the pattern in the graph as the set of graph homomorphisms
-- | `pattern → graph` — subgraph matching generalized to *any* schema, with the
-- | category doing the searching.
-- |
-- | PureScript describes the structure (here a module dependency graph) and the
-- | patterns (circular dependency, mutual dependency, diamond); Catlab returns
-- | the matches. This is the engine a Minard could use to find architectural
-- | motifs / violations in a code graph — the original Petri-net-in-Minard spark,
-- | one rung more general.
module Data.Pattern
  ( Edge
  , Graph
  , Motif
  , matches
  , writeText
  ) where

import Prelude

import Data.Array (length)
import Effect (Effect)

type Edge = { from :: Int, to :: Int }

-- | A directed graph: named nodes and edges (0-based indices into `nodes`).
type Graph = { nodes :: Array String, edges :: Array Edge }

-- | A structural motif to search for: a small graph (anonymous nodes, by count)
-- | with a human label and a glyph describing its shape.
type Motif = { name :: String, shape :: String, nodes :: Int, edges :: Array Edge }

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
