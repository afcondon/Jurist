-- | Tier-3 demo: a function-level call graph described in PureScript, migrated
-- | *functorially* (Δ along `in_mod`) to its module dependency graph. Every call
-- | becomes a module edge; we aggregate the resulting multigraph into weighted
-- | inter-module dependencies + intra-module self-loops. Writes `migration.js`
-- | for the `migration-viz/` page (the fine call graph above, the derived module
-- | graph below).
module Main where

import Prelude

import Data.Array (filter, length, nub, (!!)) as Array
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Migration (CodeGraph, Edge, Func, moduleGraph, writeText)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Effect (Effect)
import Effect.Console (log)

-- ── The typed structure ──────────────────────────────────────────────────────

modules :: Array String
modules = [ "Auth", "Db", "Api", "Util" ]

fn :: String -> Int -> Func
fn name inMod = { name, inMod }

funcs :: Array Func
funcs =
  [ fn "login" 0, fn "hashPwd" 0
  , fn "query" 1, fn "connect" 1
  , fn "handleReq" 2, fn "route" 2
  , fn "log" 3, fn "validate" 3
  ]

edge :: Int -> Int -> Edge
edge from to = { from, to }

codeGraph :: CodeGraph
codeGraph =
  { modules
  , funcs
  , calls:
      [ edge 0 2, edge 0 3                       -- Auth → Db   (×2)
      , edge 0 6, edge 1 6                       -- Auth → Util (×2)
      , edge 2 6                                 -- Db → Util   (×1)
      , edge 4 0, edge 5 1                       -- Api → Auth  (×2)
      , edge 5 2, edge 4 2, edge 4 3             -- Api → Db    (×3)
      , edge 4 6                                 -- Api → Util  (×1)
      , edge 0 1, edge 2 3                       -- intra-module: Auth, Db
      ]
  }

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
