-- | The demo structure — pure typed descriptions, shared verbatim by every
-- | denotation: the Julia workspace searches them by homomorphism; the portable
-- | workspace holds the same values and answers `Deferred`.
module Data.Pattern.Models
  ( modules
  , depGraph
  , circular
  , mutual
  , diamond
  , patterns
  ) where

import Data.Pattern (Edge, Graph, Motif)

modules :: Array String
modules = [ "Core", "Parser", "AST", "Eval", "Pretty", "Codegen", "Cli", "Utils" ]

edge :: Int -> Int -> Edge
edge a b = { from: a, to: b }

-- | A → B means "module A depends on module B".
depGraph :: Graph
depGraph =
  { nodes: modules
  , edges:
      [ edge 6 0, edge 6 1                       -- Cli → Core, Parser
      , edge 1 2, edge 2 3, edge 3 1             -- Parser → AST → Eval → Parser  (cycle)
      , edge 4 5, edge 5 4                       -- Pretty ⇄ Codegen              (mutual)
      , edge 0 7, edge 1 7                       -- Core, Parser → Utils          (→ diamond w/ Cli)
      , edge 5 2                                 -- Codegen → AST
      ]
  }

circular :: Motif
circular =
  { name: "Circular dependency", shape: "a → b → c → a", nodes: 3
  , edges: [ edge 0 1, edge 1 2, edge 2 0 ] }

mutual :: Motif
mutual =
  { name: "Mutual dependency", shape: "a ⇄ b", nodes: 2
  , edges: [ edge 0 1, edge 1 0 ] }

diamond :: Motif
diamond =
  { name: "Diamond dependency", shape: "a → (b, c) → d", nodes: 4
  , edges: [ edge 0 1, edge 0 2, edge 1 3, edge 2 3 ] }

patterns :: Array Motif
patterns = [ circular, mutual, diamond ]
