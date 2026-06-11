-- | The portable verb surface, **production denotation**: the same signatures
-- | as the Node/BEAM `Data.Verbs` (module-level backend selection), but here
-- | every verb has its production interpreter, so every answer is `Computed` —
-- | the real Symbolics gradient, the real proven enclosures, the real MTK
-- | Jacobian, the real DAE solve, the real certified optimum. A program written
-- | against this surface is textually identical across all three workspaces;
-- | only the grade of the answers differs.
module Data.Verbs
  ( exprLatex
  , gradientLatex
  , provenRoots
  , jacobianSource
  , solveDAE
  , knapsack
  , validateUnits
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Array (head)
import Data.DAESpec (DAESpec, stateVars) as DAESpec
import Data.DAESystem (buildDAEField, sampleColumns) as DAE
import Data.DAESystem (solveDAE) as DAESolve
import Data.Differentiate (exprLatex, gradientLatex) as D
import Data.Maybe (fromMaybe)
import Data.MTKSystem (buildField, jacobianSource, validateUnits) as MTK
import Data.NumExpr (NumExpr)
import Data.Optimize (knapsack) as O
import Data.Roots (provenRoots) as R
import Data.SystemSpec
  ( class NumberRow
  , class StringRow
  , class ToTexts
  , class ToValues
  , SystemSpec
  , toTextsB
  )
import Effect (Effect)
import Prim.RowList (class RowToList)
import Type.Proxy (Proxy(..))

exprLatex :: Array String -> NumExpr -> Effect (Answer String)
exprLatex vars f = Computed <$> D.exprLatex vars f

gradientLatex
  :: Array String -> Array String -> NumExpr -> Effect (Answer (Array String))
gradientLatex declare wrt f = Computed <$> D.gradientLatex declare wrt f

provenRoots
  :: String -> Number -> Number -> NumExpr -> Effect (Answer (Array (Array Number)))
provenRoots v lo hi f = Computed <$> R.provenRoots v lo hi f

-- | The analytic Jacobian MTK derives from the system description — built,
-- | simplified and differentiated symbolically, then rendered.
jacobianSource :: forall s p. SystemSpec s p -> Effect (Answer String)
jacobianSource spec = do
  field <- MTK.buildField spec
  Computed <$> MTK.jacobianSource field

-- | Solve the index-1 DAE with an implicit stiff method and answer the
-- | differential state at `t1` (in row order — the same order `stateVars`
-- | reports).
solveDAE
  :: forall state stateRL stateN stateNRL
       alg algRL algN algNRL
       params paramRL paramN paramNRL
   . RowToList state stateRL
  => NumberRow stateRL stateN
  => RowToList stateN stateNRL
  => ToValues stateNRL stateN
  => RowToList alg algRL
  => NumberRow algRL algN
  => RowToList algN algNRL
  => ToValues algNRL algN
  => RowToList params paramRL
  => NumberRow paramRL paramN
  => RowToList paramN paramNRL
  => ToValues paramNRL paramN
  => DAESpec.DAESpec state alg params
  -> Record stateN
  -> Record algN
  -> Record paramN
  -> Number
  -> Number
  -> Effect (Answer (Array Number))
solveDAE spec s0 aGuess ps t0 t1 = do
  field <- DAE.buildDAEField spec
  sol <- DAESolve.solveDAE field s0 aGuess ps t0 t1
  frames <- DAE.sampleColumns sol (DAESpec.stateVars spec) [ t1 ]
  pure (Computed (fromMaybe [] (head frames)))

knapsack :: Array Number -> Array Number -> Number -> Effect (Answer (Array Number))
knapsack weights values cap = Computed <$> O.knapsack weights values cap

-- Local `toTexts` (SystemSpec exports only the builder `toTextsB`).
toTexts :: forall row rl. RowToList row rl => ToTexts rl row => Record row -> Array String
toTexts = toTextsB (Proxy :: Proxy rl)

-- | Dimensionally validate the system against per-variable unit annotations
-- | (records matching the state/param rows, so an annotation for a misspelt
-- | variable is a compile error). The answer carries MTK's verdict and, on
-- | failure, the exact complaint naming the offending term.
validateUnits
  :: forall state stateRL stateU stateURL params paramRL paramU paramURL
   . RowToList state stateRL
  => StringRow stateRL stateU
  => RowToList stateU stateURL
  => ToTexts stateURL stateU
  => RowToList params paramRL
  => StringRow paramRL paramU
  => RowToList paramU paramURL
  => ToTexts paramURL paramU
  => SystemSpec state params
  -> Record stateU
  -> Record paramU
  -> Effect (Answer { consistent :: Boolean, report :: Array String })
validateUnits spec sUnits pUnits =
  Computed <$> MTK.validateUnits spec (toTexts sUnits) (toTexts pUnits)
