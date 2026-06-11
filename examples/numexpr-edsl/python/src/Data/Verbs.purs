-- | The portable verb surface, **Python denotation: the middle tier**.
-- |
-- | Each workspace supplies its own `Data.Verbs` with the same signatures —
-- | module-level backend selection. Python sits between the reference tier
-- | (Node/BEAM: everything `Deferred`) and Julia (everything `Computed`):
-- | sympy is a real CAS, so the symbolic-differentiation verbs answer
-- | `Computed` here, with real (sympy-rendered) LaTeX. The verbs whose
-- | production semantics Python cannot honestly supply stay `Deferred`:
-- | `provenRoots` promises *certified* enclosures (scipy guesses are not
-- | proofs), and scipy has no DAE/algebraic-variable support. The gradient
-- | of the verb matrix, made visible in one module.
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
import Data.Array (length, zipWith)
import Data.DAESpec (DAESpec, algVars, stateVars) as DAE
import Data.NumExpr (NumExpr, render)
import Data.String (joinWith)
import Data.SystemSpec
  ( class NumberRow
  , class StringRow
  , class ToTexts
  , class ToValues
  , SystemSpec
  , paramVars
  , stateVars
  , toTextsB
  )
import Effect (Effect)
import Prim.RowList (class RowToList)
import Type.Proxy (Proxy(..))

foreign import exprLatexImpl :: Array String -> NumExpr -> String
foreign import gradientLatexImpl :: Array String -> Array String -> NumExpr -> Array String

exprLatex :: Array String -> NumExpr -> Effect (Answer String)
exprLatex vars f = pure (Computed (exprLatexImpl vars f))

gradientLatex
  :: Array String -> Array String -> NumExpr -> Effect (Answer (Array String))
gradientLatex declare wrt f = pure (Computed (gradientLatexImpl declare wrt f))

provenRoots
  :: String -> Number -> Number -> NumExpr -> Effect (Answer (Array (Array Number)))
provenRoots v lo hi f = pure
  ( Deferred
      ( "proven root enclosures of [" <> render f <> "], " <> v <> " ∈ ["
          <> show lo <> ", " <> show hi
          <> "] — IntervalRootFinding, on the Julia runtime"
      )
  )

jacobianSource :: forall s p. SystemSpec s p -> Effect (Answer String)
jacobianSource spec = pure
  ( Deferred
      ( "analytic Jacobian of the ODE system in " <> show (stateVars spec)
          <> " — ModelingToolkit · Symbolics, on the Julia runtime"
      )
  )

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
  => DAE.DAESpec state alg params
  -> Record stateN
  -> Record algN
  -> Record paramN
  -> Number
  -> Number
  -> Effect (Answer (Array Number))
solveDAE spec _s0 _aGuess _ps _t0 _t1 = pure
  ( Deferred
      ( "index-1 DAE solve: state " <> show (DAE.stateVars spec)
          <> ", constraints closing " <> show (DAE.algVars spec)
          <> " — ModelingToolkit · Rodas5P (implicit, stiff), on the Julia runtime"
      )
  )

knapsack :: Array Number -> Array Number -> Number -> Effect (Answer (Array Number))
knapsack weights _values _cap = pure
  ( Deferred
      ( "proven global optimum of a 0/1 knapsack over " <> show (length weights)
          <> " items — JuMP · HiGHS, on the Julia runtime"
      )
  )

-- Local `toTexts` (SystemSpec exports only the builder `toTextsB`).
toTexts :: forall row rl. RowToList row rl => ToTexts rl row => Record row -> Array String
toTexts = toTextsB (Proxy :: Proxy rl)

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
validateUnits spec sUnits pUnits = pure
  ( Deferred
      ( "dimensional validation of the system in [" <> ann (stateVars spec) (toTexts sUnits)
          <> "], parameters [" <> ann (paramVars spec) (toTexts pUnits)
          <> "] — ModelingToolkit · DynamicQuantities, on the Julia runtime"
      )
  )
  where
  ann names units = joinWith ", " (zipWith (\n u -> n <> ":" <> u) names units)
