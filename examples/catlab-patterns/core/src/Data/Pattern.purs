-- | Tier-3 (Catlab / ACSets): structural pattern-finding by **homomorphism
-- | search**. A graph and a *pattern* are both ACSets; Catlab finds every
-- | occurrence of the pattern in the graph as the set of graph homomorphisms
-- | `pattern → graph` — subgraph matching generalized to *any* schema, with the
-- | category doing the searching.
-- |
-- | This module is the pure description language only (no foreign imports); the
-- | Julia denotation lives in `Data.Pattern.Julia` in the parent workspace, and
-- | the portable `Deferred` denotation in `examples/catlab-portable`.
module Data.Pattern
  ( Edge
  , Graph
  , Motif
  ) where

type Edge = { from :: Int, to :: Int }

-- | A directed graph: named nodes and edges (0-based indices into `nodes`).
type Graph = { nodes :: Array String, edges :: Array Edge }

-- | A structural motif to search for: a small graph (anonymous nodes, by count)
-- | with a human label and a glyph describing its shape.
type Motif = { name :: String, shape :: String, nodes :: Int, edges :: Array Edge }
