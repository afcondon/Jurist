-- | Tier-3 demo: a typed code graph (modules, functions typed into modules,
-- | calls) described in PureScript, and two architectural motifs whose *type
-- | structure* encodes the rule — a cross-module call (two distinct
-- | pattern-modules) and a shared cross-module dependency (two modules calling a
-- | third's function). Catlab finds every occurrence by typed homomorphism
-- | search. Writes `schema.js` for the `schema-viz/` page.
module Main where

import Prelude

import Data.Array (length, nubByEq, sort, (!!)) as Array
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.CodeGraph (CodeGraph, Func, Match, Motif, matches, writeText)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)

-- ── The typed structure ──────────────────────────────────────────────────────

modules :: Array String
modules = [ "Auth", "Db", "Api", "Util" ]

fn :: String -> Int -> Func
fn name inMod = { name, inMod }

funcs :: Array Func
funcs =
  [ fn "login" 0, fn "hashPwd" 0                 -- Auth
  , fn "query" 1, fn "connect" 1                 -- Db
  , fn "handleReq" 2, fn "route" 2               -- Api
  , fn "log" 3, fn "validate" 3                  -- Util
  ]

edge :: Int -> Int -> { from :: Int, to :: Int }
edge from to = { from, to }

codeGraph :: CodeGraph
codeGraph =
  { modules
  , funcs
  , calls:
      [ edge 0 2, edge 0 1, edge 0 6             -- login → query, hashPwd, log
      , edge 2 3, edge 2 6                        -- query → connect, log
      , edge 4 0, edge 4 5, edge 5 2              -- handleReq → login, route ; route → query
      , edge 7 6, edge 4 7                        -- validate → log ; handleReq → validate
      ]
  }

motifs :: Array Motif
motifs =
  [ { name: "Cross-module call", shape: "f @A → g @B", nMod: 2
    , fnMod: [ 0, 1 ], calls: [ edge 0 1 ] }
  , { name: "Shared dependency", shape: "f @A, g @B → h @C", nMod: 3
    , fnMod: [ 0, 1, 2 ], calls: [ edge 0 2, edge 1 2 ] }
  ]

-- ── Helpers ──────────────────────────────────────────────────────────────────

fnLabel :: Int -> String
fnLabel i = name <> " @" <> modName
  where
  f = funcs Array.!! i
  name = fromMaybe "?" (map _.name f)
  modName = fromMaybe "?" (f >>= \x -> modules Array.!! x.inMod)

-- A motif's matches come back with rotations/orderings; collapse to one per
-- distinct function set.
dedup :: Array Match -> Array Match
dedup = Array.nubByEq (\a b -> Array.sort a.funcs == Array.sort b.funcs)

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

funcJson :: Func -> String
funcJson f = "{\"name\":" <> jStr f.name <> ",\"inMod\":" <> show f.inMod <> "}"

-- The matched *graph* edges: each pattern call mapped through the match's
-- function map (pattern-func index → graph-func index).
matchJson :: Motif -> Match -> String
matchJson mo m =
  "{\"funcs\":" <> jIntArr m.funcs
    <> ",\"mods\":" <> jIntArr m.mods
    <> ",\"edges\":" <> jIntArr2 (map (\c -> [ at m.funcs c.from, at m.funcs c.to ]) mo.calls)
    <> "}"
  where
  at arr i = fromMaybe (-1) (arr Array.!! i)

motifJson :: Motif -> Array Match -> String
motifJson mo ms =
  "{\"name\":" <> jStr mo.name
    <> ",\"shape\":" <> jStr mo.shape
    <> ",\"matches\":" <> jArrRaw (map (matchJson mo) ms)
    <> "}"

main :: Effect Unit
main = do
  log "== Tier-3: Catlab typed-schema homomorphism search (Module / Func / Call) =="
  log ("code graph: " <> show (Array.length modules) <> " modules, "
    <> show (Array.length funcs) <> " functions, "
    <> show (Array.length codeGraph.calls) <> " calls")
  results <- traverse
    ( \mo -> do
        ms <- dedup <$> matches codeGraph mo
        log ("  " <> mo.name <> "  (" <> mo.shape <> "): " <> show (Array.length ms) <> " found")
        traverse_ (\m -> log ("      " <> joinWith ", " (map fnLabel m.funcs))) ms
        pure (motifJson mo ms)
    )
    motifs
  let
    json = "{\"modules\":" <> jArrStr modules
      <> ",\"funcs\":" <> jArrRaw (map funcJson funcs)
      <> ",\"calls\":" <> jArrRaw (map (\e -> jIntArr [ e.from, e.to ]) codeGraph.calls)
      <> ",\"motifs\":" <> jArrRaw results
      <> "}"
  writeText "schema.js" ("window.SCHEMA = " <> json <> ";\n")
  log "wrote schema.js for the schema-viz page"
