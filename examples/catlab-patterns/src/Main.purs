-- | Tier-3 demo: a module dependency graph described in PureScript, and three
-- | structural patterns — circular dependency, mutual dependency, diamond. Catlab
-- | finds every occurrence by homomorphism search (the *same* engine for every
-- | pattern). The run writes `patterns.js` for the `pattern-viz/` page, which
-- | draws the graph and highlights each pattern's matches.
module Main where

import Prelude

import Data.Array (length, nub, sort, (!!)) as Array
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Pattern (Edge, Graph, Motif, matches, writeText)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)

-- ── The structure (a typed description) ──────────────────────────────────────

modules :: Array String
modules = [ "Core", "Parser", "AST", "Eval", "Pretty", "Codegen", "Cli", "Utils" ]

edge :: Int -> Int -> Edge
edge a b = { from: a, to: b }

-- A → B means "module A depends on module B".
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

patterns :: Array Motif
patterns =
  [ { name: "Circular dependency", shape: "a → b → c → a", nodes: 3
    , edges: [ edge 0 1, edge 1 2, edge 2 0 ] }
  , { name: "Mutual dependency", shape: "a ⇄ b", nodes: 2
    , edges: [ edge 0 1, edge 1 0 ] }
  , { name: "Diamond dependency", shape: "a → (b, c) → d", nodes: 4
    , edges: [ edge 0 1, edge 0 2, edge 1 3, edge 2 3 ] }
  ]

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A match is a vertex map; canonicalise to its sorted, de-duplicated node set so
-- the rotations/orderings homomorphism search returns collapse to one occurrence.
canon :: Array Int -> Array Int
canon = Array.nub <<< Array.sort

nameOf :: Int -> String
nameOf i = fromMaybe "?" (modules Array.!! i)

jStr :: String -> String
jStr s = "\"" <> esc s <> "\""
  where
  esc =
    replaceAll (Pattern "\"") (Replacement "\\\"")
      <<< replaceAll (Pattern "\\") (Replacement "\\\\")

jArrStr :: Array String -> String
jArrStr xs = "[" <> joinWith "," (map jStr xs) <> "]"

jIntArr :: Array Int -> String
jIntArr xs = "[" <> joinWith "," (map show xs) <> "]"

jIntArr2 :: Array (Array Int) -> String
jIntArr2 xs = "[" <> joinWith "," (map jIntArr xs) <> "]"

jArrRaw :: Array String -> String
jArrRaw xs = "[" <> joinWith "," xs <> "]"

patternJson :: Motif -> Array (Array Int) -> String
patternJson p sets =
  "{\"name\":" <> jStr p.name
    <> ",\"shape\":" <> jStr p.shape
    <> ",\"matchSets\":" <> jIntArr2 sets
    <> "}"

main :: Effect Unit
main = do
  log "== Tier-3: Catlab homomorphism search — structural patterns in a code graph =="
  log ("graph: " <> show (Array.length modules) <> " modules, " <> show (Array.length depGraph.edges) <> " dependencies")
  results <- traverse
    ( \p -> do
        ms <- matches depGraph p
        let sets = Array.nub (map canon ms)
        log ("  " <> p.name <> "  (" <> p.shape <> "): " <> show (Array.length sets) <> " found")
        traverse_ (\s -> log ("      { " <> joinWith ", " (map nameOf s) <> " }")) sets
        pure (patternJson p sets)
    )
    patterns
  let
    edgesJson = jArrRaw (map (\e -> jIntArr [ e.from, e.to ]) depGraph.edges)
    json = "{\"nodes\":" <> jArrStr modules
      <> ",\"edges\":" <> edgesJson
      <> ",\"patterns\":" <> jArrRaw results
      <> "}"
  writeText "patterns.js" ("window.PATTERNS = " <> json <> ";\n")
  log "wrote patterns.js for the pattern-viz page"
