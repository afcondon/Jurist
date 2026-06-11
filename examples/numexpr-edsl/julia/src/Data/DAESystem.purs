-- | Tier-2 (increment 4): the **Julia denotation** of a row-typed
-- | differential-algebraic system. The pure description (`DAESpec`, built by
-- | `daeSystem`) lives in core's `Data.DAESpec` and compiles on every backend;
-- | this module hands it across the seam to ModelingToolkit.
-- |
-- | The whole description (one `JExpr` per equation) crosses the seam once
-- | (ADR-0002, the increment-1 currency); Julia binds the names to Symbolics
-- | variables (state *and* algebraic vars are functions of `t`; params are
-- | not), assembles a symbolic `System`, `mtkcompile`s it, and solves the
-- | resulting DAE with an implicit stiff method (`Rodas5P`) that holds the
-- | algebraic constraints by Newton iteration at every step — something a
-- | plain ODE integrator (or `scipy.solve_ivp`) cannot do.
module Data.DAESystem
  ( DAEField
  , buildDAEField
  , simplifiedEquationsSource
  , DAESolution
  , solveDAE
  , sampleColumns
  , dumpFramesJSON
  ) where

import Prelude

import Data.DAESpec (DAESpec, algVars, constraints, diffEqs, paramVars, stateVars)
import Data.NumExpr.Julia (JExpr, toJExpr)
import Data.SystemSpec (class NumberRow, class ToValues, toValuesB)
import Data.Tuple (snd)
import Effect (Effect)
import Prim.RowList (class RowToList)
import Type.Proxy (Proxy(..))

-- | An opaque handle to the Julia-side simplified symbolic DAE, carrying the
-- | three rows as phantoms so `solveDAE` is type-checked against them.
foreign import data DAEField :: Row Type -> Row Type -> Row Type -> Type

foreign import buildDAEFieldJ
  :: forall s a p
   . Array String
  -> Array String
  -> Array String
  -> Array JExpr
  -> Array JExpr
  -> Effect (DAEField s a p)

-- | Denote the DAE into ModelingToolkit and `mtkcompile` it (once).
buildDAEField :: forall s a p. DAESpec s a p -> Effect (DAEField s a p)
buildDAEField spec =
  buildDAEFieldJ (stateVars spec) (algVars spec) (paramVars spec)
    (map (toJExpr <<< snd) (diffEqs spec))
    (map (toJExpr <<< snd) (constraints spec))

foreign import simplifiedEquationsSourceJ :: forall s a p. DAEField s a p -> Effect String

-- | The simplified symbolic equations MTK produced — shows the index-1 DAE
-- | structure (differential equations plus the algebraic constraints that
-- | determine the algebraic variables).
simplifiedEquationsSource :: forall s a p. DAEField s a p -> Effect String
simplifiedEquationsSource = simplifiedEquationsSourceJ

-- | An opaque handle to a solved DAE (a Julia `ODESolution` over the simplified
-- | system, plus the symbolic-variable map for by-name sampling).
foreign import data DAESolution :: Type

foreign import solveDAEJ
  :: forall s a p
   . DAEField s a p
  -> Array Number
  -> Array Number
  -> Array Number
  -> Number
  -> Number
  -> Effect DAESolution

-- Local `toValues` (SystemSpec exports only the builder `toValuesB`).
toValues :: forall row rl. RowToList row rl => ToValues rl row => Record row -> Array Number
toValues = toValuesB (Proxy :: Proxy rl)

-- | Solve the DAE over `[t0, t1]`. Differential variables take initial
-- | conditions (`s0`); algebraic variables take *guesses* (`aGuess`) for the
-- | consistent-initialization solve; parameters take values (`ps`). All three
-- | are records matching the system's rows, read in row order so they line up
-- | with the compiled system. The implicit stiff solver maintains the algebraic
-- | constraints at every step.
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
  => DAEField state alg params
  -> Record stateN
  -> Record algN
  -> Record paramN
  -> Number
  -> Number
  -> Effect DAESolution
solveDAE field s0 aGuess ps t0 t1 =
  solveDAEJ field (toValues s0) (toValues aGuess) (toValues ps) t0 t1

foreign import sampleColumnsJ
  :: DAESolution -> Array String -> Array Number -> Effect (Array (Array Number))

-- | Sample named variables (by their symbolic identity, robust to any internal
-- | reordering) at the requested times. One inner array per time, columns in the
-- | order requested — the "handles back" materialization, on demand.
sampleColumns :: DAESolution -> Array String -> Array Number -> Effect (Array (Array Number))
sampleColumns = sampleColumnsJ

foreign import dumpFramesJSONJ
  :: DAESolution -> Array String -> Array Number -> String -> String -> Effect Unit

-- | Sample the named columns at the given times and write them, plus a metadata
-- | string (raw JSON object body, e.g. `"\"L1\":1.0,\"L2\":1.0"`), to a JSON file
-- | — the bulk animation data stays Julia-owned until it lands on disk.
dumpFramesJSON
  :: DAESolution -> Array String -> Array Number -> String -> String -> Effect Unit
dumpFramesJSON = dumpFramesJSONJ
