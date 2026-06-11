-- | Tier-3 demo: a module dependency graph described in PureScript, and three
-- | structural patterns — circular dependency, mutual dependency, diamond. Catlab
-- | finds every occurrence by homomorphism search (the *same* engine for every
-- | pattern). The run writes `patterns.js` for the `pattern-viz/` page, which
-- | draws the graph and highlights each pattern's matches.
module Main where

import Prelude

import Data.Answer (describe)
import Data.Array (length, nub, sort, (!!)) as Array
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Pattern (Motif)
import Data.Pattern.Julia (matches, writeText)
import Data.Pattern.Models (circular, depGraph, modules, patterns)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.Traversable (traverse)
import Data.Verbs (matches) as V
import Effect (Effect)
import Effect.Console (log)

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

  -- The verb surface: the same call answers `Deferred` on the portable
  -- denotation (examples/catlab-portable); here, the real homomorphisms.
  log "\n== the verb surface: this runtime's answer =="
  vm <- V.matches depGraph circular
  log ("matches depGraph circular: "
    <> describe (\ms -> show (Array.length ms) <> " homomorphisms") vm)
