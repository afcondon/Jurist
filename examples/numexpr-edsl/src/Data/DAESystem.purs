-- | Tier-2 (increment 4): a row-typed **differential-algebraic** system on top
-- | of the `NumExpr` eDSL, denoted into ModelingToolkit. Where `SystemSpec`
-- | (increments 2 & 3) is a pure system of ODEs, a `DAESpec` adds *algebraic
-- | variables* — quantities with no time derivative — and one *algebraic
-- | constraint* per algebraic variable. This is the shape of a constrained
-- | mechanical system: a double pendulum in Cartesian coordinates has positions
-- | and velocities (differential state) plus rod tensions (algebraic), closed by
-- | the rigidity constraints.
-- |
-- | Three rows now: `state` (differential), `alg` (algebraic), `params`. The
-- | system is two lambdas:
-- |
-- | ```purescript
-- | dae = daeSystem
-- |   -- D(state_i) ~ rhs : one differential equation per state variable
-- |   (\s a p -> { x1: s.u1, … , u1: (negate a.t1 * s.x1 + …) `divide` p.m1, … })
-- |   -- 0 ~ g_j : one closing constraint per *algebraic* variable
-- |   (\s a p -> { t1: …accel-level rod-1 constraint… , t2: … })
-- | ```
-- |
-- | Because the constraint lambda returns a `Record alg`, the type system forces
-- | *exactly one* closing constraint per algebraic variable — a well-posed
-- | index-1 DAE by construction. The whole description (one `JExpr` per equation)
-- | crosses the seam once (ADR-0002, the increment-1 currency); Julia binds the
-- | names to Symbolics variables (state *and* algebraic vars are functions of
-- | `t`; params are not), assembles a symbolic `System`, `mtkcompile`s it, and
-- | solves the resulting DAE with an implicit stiff method (`Rodas5P`) that holds
-- | the algebraic constraints by Newton iteration at every step — something a
-- | plain ODE integrator (or `scipy.solve_ivp`) cannot do.
-- |
-- | Reuses the RowList machinery from `Data.SystemSpec` (`MakeVars`, `Keys`,
-- | `CollectEqs`, `ToValues`, `NumberRow`) — the DAE surface is the same
-- | row-typed idea with an extra row.
module Data.DAESystem
  ( DAESpec
  , daeSystem
  , stateVars
  , algVars
  , paramVars
  , DAEField
  , buildDAEField
  , simplifiedEquationsSource
  , DAESolution
  , solveDAE
  , sampleColumns
  , dumpFramesJSON
  ) where

import Prelude

import Data.NumExpr (JExpr, NumExpr, toJExpr)
import Data.SystemSpec
  ( class CollectEqs
  , class Keys
  , class MakeVars
  , class NumberRow
  , class ToValues
  , collectEqs
  , keysB
  , makeVarsB
  , toValuesB
  )
import Data.Tuple (Tuple, snd)
import Effect (Effect)
import Prim.RowList (class RowToList)
import Record.Builder as Builder
import Type.Proxy (Proxy(..))

newtype DAESpec (state :: Row Type) (alg :: Row Type) (params :: Row Type) = DAESpec
  { diffEqs :: Array (Tuple String NumExpr)
  , constraints :: Array (Tuple String NumExpr)
  , stateVars :: Array String
  , algVars :: Array String
  , paramVars :: Array String
  }

stateVars :: forall s a p. DAESpec s a p -> Array String
stateVars (DAESpec r) = r.stateVars

algVars :: forall s a p. DAESpec s a p -> Array String
algVars (DAESpec r) = r.algVars

paramVars :: forall s a p. DAESpec s a p -> Array String
paramVars (DAESpec r) = r.paramVars

-- Local `makeVars` (SystemSpec exports only the builder `makeVarsB`).
makeVars :: forall row rl. RowToList row rl => MakeVars rl row => Record row
makeVars = Builder.build (makeVarsB (Proxy :: Proxy rl)) {}

-- | Assemble a typed DAE. The first lambda gives the RHS of each differential
-- | equation (one field per `state` variable); the second gives the closing
-- | constraint for each algebraic variable (one field per `alg` variable, each
-- | read as `0 ~ field`). Both lambdas see the typed state/alg/param records, so
-- | every field access is checked — a misspelt variable is a compile error, and
-- | the constraint count is pinned to the algebraic-variable count.
daeSystem
  :: forall state stateRL alg algRL params paramRL
   . RowToList state stateRL
  => MakeVars stateRL state
  => Keys stateRL
  => CollectEqs stateRL state
  => RowToList alg algRL
  => MakeVars algRL alg
  => Keys algRL
  => CollectEqs algRL alg
  => RowToList params paramRL
  => MakeVars paramRL params
  => Keys paramRL
  => (Record state -> Record alg -> Record params -> Record state)
  -> (Record state -> Record alg -> Record params -> Record alg)
  -> DAESpec state alg params
daeSystem diff cons = DAESpec
  { diffEqs: collectEqs (Proxy :: Proxy stateRL) (diff s a p)
  , constraints: collectEqs (Proxy :: Proxy algRL) (cons s a p)
  , stateVars: keysB (Proxy :: Proxy stateRL)
  , algVars: keysB (Proxy :: Proxy algRL)
  , paramVars: keysB (Proxy :: Proxy paramRL)
  }
  where
  s = makeVars :: Record state
  a = makeVars :: Record alg
  p = makeVars :: Record params

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
buildDAEField (DAESpec r) =
  buildDAEFieldJ r.stateVars r.algVars r.paramVars
    (map (toJExpr <<< snd) r.diffEqs)
    (map (toJExpr <<< snd) r.constraints)

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
