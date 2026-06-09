-- | Tier-2 (increment 3): denote a row-typed `SystemSpec` into
-- | **ModelingToolkit**. Where `Data.SystemSpec.integrate` compiles the vector
-- | field to a native lambda and runs a *hand-written, fixed-step* RK4, this
-- | module hands the same description across the seam and lets Julia's symbolic
-- | stack do the heavy lifting:
-- |
-- |  * the equations become a symbolic `ODESystem`;
-- |  * `structural_simplify` runs MTK's equation-level rewrites;
-- |  * MTK derives the **analytic Jacobian** (and sparsity) — derivatives the
-- |    PureScript side never wrote;
-- |  * the problem is solved by a real **stiff-aware adaptive** integrator
-- |    (`Rodas5`), with dense output we sample lazily.
-- |
-- | The seam is unchanged from increments 1 & 2 (ADR-0002, ADR-0007): PureScript
-- | hands across *descriptions* — the ordered variable names plus one `JExpr`
-- | per state equation, folded through the `Data.NumExpr` builders so the shim
-- | never destructures a PureScript ADT. Julia denotes those `JExpr`s into
-- | Symbolics variables, builds the system, and keeps it. Nothing about MTK
-- | leaks into the PureScript types: `MTKField`/`Solution` are opaque handles,
-- | and the state/param rows ride along as phantoms so `solve` stays
-- | type-checked against the system it was built from (a misspelt initial
-- | condition is a compile error).
-- |
-- | A `Solution` is the "handles back" half of the doctrine made literal: the
-- | orbit lives in Julia (the solver's dense interpolant), and PureScript pulls
-- | back only what it asks for — `sampleAt` a set of times, `finalState`, or a
-- | single `maxComponent` — rather than materialising every solver step.
module Data.MTKSystem
  ( MTKField
  , buildField
  , equationsSource
  , jacobianSource
  , Solution
  , solve
  , sampleAt
  , finalState
  , maxComponent
  ) where

import Prelude

import Data.NumExpr (JExpr, toJExpr)
import Data.SystemSpec
  ( SystemSpec
  , class NumberRow
  , class ToValues
  , equations
  , paramVars
  , stateVars
  , toValuesB
  )
import Data.Tuple (snd)
import Effect (Effect)
import Prim.RowList (class RowToList)
import Type.Proxy (Proxy(..))

-- | Read a `Number`-valued record's values in row (alphabetical) order, so they
-- | line up with the variable order baked into the `MTKField`. Reconstructed
-- | here from `SystemSpec`'s exported `toValuesB` rather than threading a public
-- | `toValues` through that module.
toValues :: forall row rl. RowToList row rl => ToValues rl row => Record row -> Array Number
toValues = toValuesB (Proxy :: Proxy rl)

-- | An opaque handle to an MTK system built from a `SystemSpec`: the
-- | `structural_simplify`d `ODESystem` plus the state/param variable order.
-- | The phantom rows are PureScript-only (erased at runtime), so the foreign is
-- | free to return them polymorphically; `buildField` pins them from the spec.
foreign import data MTKField :: Row Type -> Row Type -> Type

-- | An opaque handle to a solved trajectory — the solver's `ODESolution`,
-- | carrying a dense interpolant. Sampled lazily from PureScript; never
-- | materialised wholesale across the seam.
foreign import data Solution :: Type

foreign import buildFieldJ
  :: forall s p. Array String -> Array String -> Array JExpr -> Effect (MTKField s p)

foreign import equationsSourceJ :: forall s p. MTKField s p -> Effect String

foreign import jacobianSourceJ :: forall s p. MTKField s p -> Effect String

foreign import solveJ
  :: forall s p
   . MTKField s p -> Array Number -> Array Number -> Number -> Number -> Effect Solution

foreign import sampleAtJ :: Solution -> Array Number -> Effect (Array (Array Number))

foreign import finalStateJ :: Solution -> Effect (Array Number)

foreign import maxComponentJ :: Solution -> Int -> Effect Number

-- | Denote a typed system into an MTK `ODESystem` (built and simplified once).
buildField :: forall s p. SystemSpec s p -> Effect (MTKField s p)
buildField spec =
  buildFieldJ (stateVars spec) (paramVars spec) (map (toJExpr <<< snd) (equations spec))

-- | The simplified system's equations, as Julia renders them — evidence the
-- | symbolic round-trip landed (the PureScript-described RHS, now a real
-- | symbolic `ODESystem`).
equationsSource :: forall s p. MTKField s p -> Effect String
equationsSource = equationsSourceJ

-- | The analytic Jacobian MTK derived from the system, as a rendered matrix —
-- | derivatives PureScript never wrote, computed symbolically on the Julia side.
jacobianSource :: forall s p. MTKField s p -> Effect String
jacobianSource = jacobianSourceJ

-- | Solve over `[t0, t1]` with a stiff-aware adaptive integrator. Initial
-- | conditions and parameters are records matching the system's rows (read in
-- | row order to line up with the field's variable order); a missing or
-- | misspelt field is a compile error. Returns a lazy `Solution` handle.
solve
  :: forall state stateRL stateN stateNRL params paramRL paramN paramNRL
   . RowToList state stateRL
  => NumberRow stateRL stateN
  => RowToList stateN stateNRL
  => ToValues stateNRL stateN
  => RowToList params paramRL
  => NumberRow paramRL paramN
  => RowToList paramN paramNRL
  => ToValues paramNRL paramN
  => MTKField state params
  -> Record stateN
  -> Record paramN
  -> Number
  -> Number
  -> Effect Solution
solve field s0 ps t0 t1 = solveJ field (toValues s0) (toValues ps) t0 t1

-- | Sample the dense solution at the given times — the orbit stays Julia-side;
-- | only the requested points cross back.
sampleAt :: Solution -> Array Number -> Effect (Array (Array Number))
sampleAt = sampleAtJ

-- | The state vector at the end of the integration interval.
finalState :: Solution -> Effect (Array Number)
finalState = finalStateJ

-- | The maximum value attained by one state component (0-based index, in row
-- | order) over the whole trajectory — computed Julia-side without pulling the
-- | orbit across.
maxComponent :: Solution -> Int -> Effect Number
maxComponent = maxComponentJ
