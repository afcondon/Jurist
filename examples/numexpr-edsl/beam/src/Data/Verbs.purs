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
  , jacobianSource
  , solveDAE
  , knapsack
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Array (length)
import Data.DAESpec (DAESpec, algVars, stateVars) as DAE
import Data.NumExpr (NumExpr, render)
import Data.SystemSpec (class NumberRow, class ToValues, SystemSpec, stateVars)
import Effect (Effect)
import Prim.RowList (class RowToList)

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
