-- | Tier-3 demo: a function-level call graph described in PureScript, migrated
-- | *functorially* (Δ along `in_mod`) to its module dependency graph. Every call
-- | becomes a module edge; we aggregate the resulting multigraph into weighted
-- | inter-module dependencies + intra-module self-loops. Writes `migration.js`
-- | for the `migration-viz/` page (the fine call graph above, the derived module
-- | graph below).
module Main where

import Prelude

import Data.Answer (describe)
import Data.Array (filter, length, nub, (!!)) as Array
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Migration (Func)
import Data.Migration.Julia (moduleGraph, writeText)
import Data.Migration.Models (codeGraph, funcs, modules)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.Verbs (moduleGraph) as V
import Effect (Effect)
import Effect.Console (log)

-- ── Aggregate the migrated multigraph into weighted edges ────────────────────

type WEdge = { from :: Int, to :: Int, weight :: Int }

aggregate :: Array (Array Int) -> Array WEdge
aggregate raw =
  map (\d -> { from: d.from, to: d.to, weight: Array.length (Array.filter (sameAs d) pairs) })
    (Array.nub pairs)
  where
  pairs = map (\e -> { from: at e 0, to: at e 1 }) raw
  at e i = fromMaybe 0 (e Array.!! i)
  sameAs d p = p.from == d.from && p.to == d.to

modName :: Int -> String
modName i = fromMaybe "?" (modules Array.!! i)

-- ── JSON ─────────────────────────────────────────────────────────────────────

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

jArrRaw :: Array String -> String
jArrRaw xs = "[" <> joinWith "," xs <> "]"

funcJson :: Func -> String
funcJson f = "{\"name\":" <> jStr f.name <> ",\"inMod\":" <> show f.inMod <> "}"

wedgeJson :: WEdge -> String
wedgeJson e = "{\"from\":" <> show e.from <> ",\"to\":" <> show e.to <> ",\"weight\":" <> show e.weight <> "}"

selfJson :: WEdge -> String
selfJson e = "{\"mod\":" <> show e.from <> ",\"weight\":" <> show e.weight <> "}"

main :: Effect Unit
main = do
  log "== Tier-3: functorial data migration — call graph ⇒ module dependency graph =="
  raw <- moduleGraph codeGraph
  let
    agg = aggregate raw
    inter = Array.filter (\e -> e.from /= e.to) agg
    selfs = Array.filter (\e -> e.from == e.to) agg
  log ("migrated " <> show (Array.length raw) <> " calls → "
    <> show (Array.length inter) <> " module dependencies (+ "
    <> show (Array.length selfs) <> " intra-module)")
  traverse_ (\e -> log ("   " <> modName e.from <> " → " <> modName e.to <> "   (×" <> show e.weight <> ")")) inter
  let
    json = "{\"modules\":" <> jArrStr modules
      <> ",\"funcs\":" <> jArrRaw (map funcJson funcs)
      <> ",\"calls\":" <> jArrRaw (map (\e -> jIntArr [ e.from, e.to ]) codeGraph.calls)
      <> ",\"moduleEdges\":" <> jArrRaw (map wedgeJson inter)
      <> ",\"selfLoops\":" <> jArrRaw (map selfJson selfs)
      <> "}"
  writeText "migration.js" ("window.MIGRATION = " <> json <> ";\n")
  log "wrote migration.js for the migration-viz page"

  -- The verb surface: the same call answers `Deferred` on the portable
  -- denotation (examples/catlab-portable); here, the real migrated graph.
  log "\n== the verb surface: this runtime's answer =="
  vg <- V.moduleGraph codeGraph
  log ("moduleGraph codeGraph: "
    <> describe (\es -> show (Array.length es) <> " migrated edges") vg)
