-- | The **Julia (production) denotation** of the backend-agnostic
-- | `Data.SystemSpec`. `Data.SystemSpec` (in the `core` package) holds the
-- | row-typed description, the `system` builder, the RowList machinery, and the
-- | pure `integratePure` develop-anywhere denotation — all FFI-free. This
-- | module compiles the *same* `SystemSpec`'s vector field to a native Julia
-- | RHS (one fused `RuntimeGeneratedFunction`, ADR-0007) and integrates it with
-- | a native RK4 loop.
-- |
-- | The seam is crossed once: PureScript hands across the ordered variable
-- | names plus one `JExpr` per equation (folded through `Data.NumExpr.Julia`),
-- | and Julia owns everything after. `Field` carries the system's state/param
-- | rows as phantoms so `integrate` stays type-checked against the system it was
-- | compiled from. One description, two denotations — this and
-- | `Data.SystemSpec.integratePure` — cross-checked in `Main`.
module Data.SystemSpec.Julia
  ( Field
  , compileField
  , integrate
  ) where

import Prelude

import Data.NumExpr.Julia (JExpr, toJExpr)
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
-- | line up with the variable order baked into the compiled `Field`.
-- | Reconstructed from `core`'s exported `toValuesB` (which exports only the
-- | builder, not a public `toValues`).
toValues :: forall row rl. RowToList row rl => ToValues rl row => Record row -> Array Number
toValues = toValuesB (Proxy :: Proxy rl)

-- | An opaque handle to a Julia-compiled vector field, carrying the system's
-- | state/param rows as phantoms so `integrate` is type-checked against them.
foreign import data Field :: Row Type -> Row Type -> Type

-- The phantom rows are PS-only (erased at runtime), so the foreign is free to
-- return them polymorphically; `compileField` pins them from the SystemSpec.
foreign import compileFieldJ
  :: forall s p. Array String -> Array String -> Array JExpr -> Effect (Field s p)

foreign import integrateJ
  :: forall s p
   . Field s p -> Array Number -> Array Number -> Number -> Int -> Effect (Array (Array Number))

-- | Compile a system's vector field into native Julia code (once).
compileField :: forall s p. SystemSpec s p -> Effect (Field s p)
compileField spec =
  compileFieldJ (stateVars spec) (paramVars spec) (map (toJExpr <<< snd) (equations spec))

-- | Integrate the field with native RK4. Initial conditions and parameters are
-- | records matching the system's rows; values are read in row order so they
-- | line up with the compiled field. Returns the orbit (state per step).
integrate
  :: forall state stateRL stateN stateNRL params paramRL paramN paramNRL
   . RowToList state stateRL
  => NumberRow stateRL stateN
  => RowToList stateN stateNRL
  => ToValues stateNRL stateN
  => RowToList params paramRL
  => NumberRow paramRL paramN
  => RowToList paramN paramNRL
  => ToValues paramNRL paramN
  => Field state params
  -> Record stateN
  -> Record paramN
  -> Number
  -> Int
  -> Effect (Array (Array Number))
integrate field s0 ps dt steps =
  integrateJ field (toValues s0) (toValues ps) dt steps
