-- | Tier-2, the differentiation round-trip: hand a `NumExpr` across the seam and
-- | get its **exact symbolic derivatives** back — derivatives PureScript never
-- | wrote. Julia binds the expression's variables to Symbolics scalars, denotes
-- | the handed-over `JExpr` against them (the increment-1 currency; the shim
-- | never destructures a PureScript ADT), differentiates with `Symbolics`, and
-- | renders the result two ways:
-- |
-- |  * `*Latex` — `Latexify.latexify` on the symbolic derivative, i.e. a
-- |    publication-quality LaTeX string (real `\frac`, `\sqrt`, `\cos`). The
-- |    visible payoff: the chain rule typeset, never hand-derived.
-- |
-- | This is the "descriptions across, **descriptions back**" inversion: what
-- | comes back is not a number or an opaque handle but math you can read.
module Data.Differentiate
  ( exprLatex
  , gradientLatex
  , writeText
  ) where

import Prelude

import Data.NumExpr (NumExpr)
import Data.NumExpr.Julia (JExpr, toJExpr)
import Effect (Effect)

-- The first array DECLARES the Symbolics scalars every free Symbol in the
-- expression resolves against (state vars *and* parameters); the second names
-- which of them to differentiate by. The gradient is one derivative per
-- differentiation variable.
foreign import exprLatexJ :: Array String -> JExpr -> Effect String
foreign import gradientLatexJ :: Array String -> Array String -> JExpr -> Effect (Array String)
foreign import writeTextJ :: String -> String -> Effect Unit

-- | The expression itself, as LaTeX (the simplified Symbolics form). `declare`
-- | must list every variable appearing in the expression.
exprLatex :: Array String -> NumExpr -> Effect String
exprLatex declare e = exprLatexJ declare (toJExpr e)

-- | The gradient as LaTeX — one `∂f/∂vᵢ` per `wrt` variable, in order. `declare`
-- | lists every variable in the expression; `wrt` the subset to differentiate by
-- | (e.g. declare state + params, differentiate by state for a Jacobian row).
gradientLatex :: Array String -> Array String -> NumExpr -> Effect (Array String)
gradientLatex declare wrt e = gradientLatexJ declare wrt (toJExpr e)

-- | Write a string to a file (the assembled JSON the KaTeX page reads).
writeText :: String -> String -> Effect Unit
writeText = writeTextJ
