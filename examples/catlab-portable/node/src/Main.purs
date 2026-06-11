-- | The same descriptions the Julia workspaces compute from — `sir`,
-- | `depGraph`/`circular`, `codeGraph` are imported from the shared cores, not
-- | copied — run against this runtime's `Data.Verbs`. Every answer here is
-- | `Deferred`: an honest, typed IOU naming the production interpreter that
-- | will compute it (ADR-0007).
module Main where

import Prelude

import Data.Answer (describe)
import Data.Array (length) as Array
import Data.Migration.Models (codeGraph)
import Data.Pattern.Models (circular, depGraph)
import Data.Petri.Models (sir)
import Data.String (joinWith)
import Data.Verbs (matches, moduleGraph, odeLaws)
import Effect (Effect)
import Effect.Console (log)

main :: Effect Unit
main = do
  log "== the Catlab verb surface: same descriptions, this runtime's answers =="
  laws <- odeLaws sir
  log ("odeLaws sir:               " <> describe (joinWith "   ") laws)
  ms <- matches depGraph circular
  log ("matches depGraph circular: "
    <> describe (\xs -> show (Array.length xs) <> " homomorphisms") ms)
  mg <- moduleGraph codeGraph
  log ("moduleGraph codeGraph:     "
    <> describe (\xs -> show (Array.length xs) <> " migrated edges") mg)
