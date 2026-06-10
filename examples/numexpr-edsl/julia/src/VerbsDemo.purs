-- | The same program, three runtimes. This module is byte-identical in the
-- | node/, beam/ and julia/ workspaces; what differs is which `Data.Verbs`
-- | it compiles against. On Node and the BEAM the production verbs answer
-- | with a typed `Deferred` placeholder — the program still type-checks,
-- | runs, and renders honestly; no stub masquerades as data. On Julia the
-- | same calls answer `Computed`, with the real gradient and the real proven
-- | enclosures (ADR-0007: one description, a hierarchy of interpreters).
module VerbsDemo (run) where

import Prelude

import Data.Answer (describe)
import Data.NumExpr (NumExpr, logE, num, pow, sinE, var)
import Data.Verbs (gradientLatex, provenRoots)
import Effect (Effect)
import Effect.Console (log)

-- The differentiation showcase: 10x² − xy + sin y + log x.
showcase :: NumExpr
showcase =
  num 10.0 * pow (var "x") (num 2.0)
    - var "x" * var "y"
    + sinE (var "y")
    + logE (var "x")

run :: Effect Unit
run = do
  log "\n== the verb surface: same program, this runtime's answers =="
  grad <- gradientLatex [ "x", "y" ] [ "x", "y" ] showcase
  log ("∇f:    " <> describe show grad)
  let x = var "x"
  roots <- provenRoots "x" (-3.0) 3.0 (x * x * x - num 2.0 * x - num 5.0)
  log ("roots: " <> describe show roots)
