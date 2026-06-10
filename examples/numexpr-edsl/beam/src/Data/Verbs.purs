-- | The portable verb surface, **reference denotation**: typed placeholders.
-- |
-- | Each workspace supplies its own `Data.Verbs` with the same signatures —
-- | module-level backend selection, the same trick as core's per-backend math
-- | shims, one level up. Here (Node, and identically on the BEAM) the
-- | production interpreters don't exist, so every verb answers `Deferred`
-- | with a rendering of the description it would consume: the host can hold,
-- | type-check, display and pipeline the computation; the answers arrive when
-- | the same program runs on the Julia denotation (`julia/src/Data/Verbs.purs`,
-- | which wraps the real interpreters in `Computed`).
module Data.Verbs
  ( exprLatex
  , gradientLatex
  , provenRoots
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.NumExpr (NumExpr, render)
import Effect (Effect)

exprLatex :: Array String -> NumExpr -> Effect (Answer String)
exprLatex _ f = pure
  (Deferred ("LaTeX of [" <> render f <> "] — Latexify, on the Julia runtime"))

gradientLatex
  :: Array String -> Array String -> NumExpr -> Effect (Answer (Array String))
gradientLatex _ wrt f = pure
  ( Deferred
      ( "∇[" <> render f <> "] wrt " <> show wrt
          <> " — Symbolics · Latexify, on the Julia runtime"
      )
  )

provenRoots
  :: String -> Number -> Number -> NumExpr -> Effect (Answer (Array (Array Number)))
provenRoots v lo hi f = pure
  ( Deferred
      ( "proven root enclosures of [" <> render f <> "], " <> v <> " ∈ ["
          <> show lo <> ", " <> show hi
          <> "] — IntervalRootFinding, on the Julia runtime"
      )
  )
