-- | The portable verb surface, **production denotation**: the same signatures
-- | as the Node/BEAM `Data.Verbs` (module-level backend selection), but here
-- | every verb has its production interpreter, so every answer is `Computed` —
-- | the real Symbolics gradient, the real proven enclosures. A program written
-- | against this surface is textually identical across all three workspaces;
-- | only the grade of the answers differs.
module Data.Verbs
  ( exprLatex
  , gradientLatex
  , provenRoots
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Differentiate (exprLatex, gradientLatex) as D
import Data.NumExpr (NumExpr)
import Data.Roots (provenRoots) as R
import Effect (Effect)

exprLatex :: Array String -> NumExpr -> Effect (Answer String)
exprLatex vars f = Computed <$> D.exprLatex vars f

gradientLatex
  :: Array String -> Array String -> NumExpr -> Effect (Answer (Array String))
gradientLatex declare wrt f = Computed <$> D.gradientLatex declare wrt f

provenRoots
  :: String -> Number -> Number -> NumExpr -> Effect (Answer (Array (Array Number)))
provenRoots v lo hi f = Computed <$> R.provenRoots v lo hi f
