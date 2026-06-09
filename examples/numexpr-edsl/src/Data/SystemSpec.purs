-- | Tier-2 (increment 2): a row-typed dynamical-system surface on top of the
-- | `NumExpr` eDSL. A `SystemSpec state params` is a system of ODEs whose
-- | state space and parameters are PureScript *rows*, so the RHS lambdas
-- | access them by typed field — a misspelt `s.q` is a compile error.
-- |
-- | ```purescript
-- | lorenz :: SystemSpec (x :: NumExpr, y :: NumExpr, z :: NumExpr)
-- |                      (sigma :: NumExpr, rho :: NumExpr, beta :: NumExpr)
-- | lorenz = system
-- |   { x: \s p -> p.sigma * (s.y - s.x)
-- |   , y: \s p -> s.x * (p.rho - s.z) - s.y
-- |   , z: \s p -> s.x * s.y - p.beta * s.z
-- |   }
-- | ```
-- |
-- | The lambdas do *not* build runtime closures — `s.x` is `var "x"`, so each
-- | lambda builds a `NumExpr` AST. The whole vector field crosses the seam
-- | once (the `NumExpr` staging of increment 1) and Julia compiles it into a
-- | native RHS, then integrates it with a native RK4 loop. The state/param
-- | rows flow through `SystemSpec → Field → integrate`, so initial conditions
-- | and parameters must match the system by type, and the alphabetical
-- | RowList order is used consistently on both sides (no positional mixups).
module Data.SystemSpec
  ( SystemSpec
  , system
  , stateVars
  , paramVars
  , equations
  , Field
  , compileField
  , integrate
  , class MakeVars
  , makeVarsB
  , class Keys
  , keysB
  , class CollectEqs
  , collectEqs
  , class ToValues
  , toValuesB
  , class NumberRow
  ) where

import Prelude

import Data.Array ((:))
import Data.NumExpr (JExpr, NumExpr, toJExpr, var)
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.Tuple (Tuple(..), snd)
import Effect (Effect)
import Prim.Row as Row
import Prim.RowList (class RowToList, Cons, Nil, RowList)
import Record as Record
import Record.Builder (Builder)
import Record.Builder as Builder
import Type.Proxy (Proxy(..))

newtype SystemSpec (state :: Row Type) (params :: Row Type) = SystemSpec
  { eqs :: Array (Tuple String NumExpr)
  , stateVars :: Array String
  , paramVars :: Array String
  }

stateVars :: forall s p. SystemSpec s p -> Array String
stateVars (SystemSpec r) = r.stateVars

paramVars :: forall s p. SystemSpec s p -> Array String
paramVars (SystemSpec r) = r.paramVars

equations :: forall s p. SystemSpec s p -> Array (Tuple String NumExpr)
equations (SystemSpec r) = r.eqs

-- | Build a record of variable references: each field becomes `var <label>`.
class MakeVars (rl :: RowList Type) (row :: Row Type) | rl -> row where
  makeVarsB :: Proxy rl -> Builder {} { | row }

instance makeVarsNil :: MakeVars Nil () where
  makeVarsB _ = identity

instance makeVarsCons ::
  ( IsSymbol name
  , MakeVars tail tailRow
  , Row.Lacks name tailRow
  , Row.Cons name NumExpr tailRow row
  ) =>
  MakeVars (Cons name NumExpr tail) row where
  makeVarsB _ =
    Builder.insert (Proxy :: _ name) (var (reflectSymbol (Proxy :: _ name)))
      <<< makeVarsB (Proxy :: _ tail)

makeVars :: forall row rl. RowToList row rl => MakeVars rl row => Record row
makeVars = Builder.build (makeVarsB (Proxy :: Proxy rl)) {}

-- | The ordered labels of a row (alphabetical, per RowList).
class Keys (rl :: RowList Type) where
  keysB :: Proxy rl -> Array String

instance keysNil :: Keys Nil where
  keysB _ = []

instance keysCons :: (IsSymbol name, Keys tail) => Keys (Cons name ty tail) where
  keysB _ = reflectSymbol (Proxy :: Proxy name) : keysB (Proxy :: Proxy tail)

-- | Collect the RHS expressions from a record of `NumExpr`s, in row order.
class CollectEqs (rl :: RowList Type) (eqs :: Row Type) where
  collectEqs :: Proxy rl -> Record eqs -> Array (Tuple String NumExpr)

instance collectNil :: CollectEqs Nil eqs where
  collectEqs _ _ = []

instance collectCons ::
  ( IsSymbol name
  , Row.Cons name NumExpr rest eqs
  , CollectEqs tail eqs
  ) =>
  CollectEqs (Cons name NumExpr tail) eqs where
  collectEqs _ rec =
    Tuple (reflectSymbol nameP) (Record.get nameP rec)
      : collectEqs (Proxy :: Proxy tail) rec
    where
    nameP = Proxy :: Proxy name

-- | Read a record's values in row (alphabetical) order — used to line initial
-- | conditions / parameters up with the compiled field's variable order.
class ToValues (rl :: RowList Type) (row :: Row Type) where
  toValuesB :: Proxy rl -> Record row -> Array Number

instance toValuesNil :: ToValues Nil row where
  toValuesB _ _ = []

instance toValuesCons ::
  ( IsSymbol name
  , Row.Cons name Number rest row
  , ToValues tail row
  ) =>
  ToValues (Cons name Number tail) row where
  toValuesB _ rec = Record.get nameP rec : toValuesB (Proxy :: Proxy tail) rec
    where
    nameP = Proxy :: Proxy name

toValues :: forall row rl. RowToList row rl => ToValues rl row => Record row -> Array Number
toValues = toValuesB (Proxy :: Proxy rl)

-- | Relate a `NumExpr`-valued row (the system's state/params) to the
-- | `Number`-valued row of concrete values with the same labels — so initial
-- | conditions and parameters stay type-checked against the system while
-- | carrying numbers.
class NumberRow (rl :: RowList Type) (numbers :: Row Type) | rl -> numbers

instance numberRowNil :: NumberRow Nil ()

instance numberRowCons ::
  ( NumberRow tail tailN
  , Row.Cons name Number tailN numbers
  ) =>
  NumberRow (Cons name NumExpr tail) numbers

-- | Assemble a typed system from a function over the typed state/param
-- | records, returning a record of RHS expressions (one per state variable).
-- | The lambda's `s`/`p` are pinned to `Record state`/`Record params` by this
-- | signature, so `s.q` for an absent field is a compile error.
system
  :: forall state stateRL params paramRL eqs eqsRL
   . RowToList state stateRL
  => MakeVars stateRL state
  => Keys stateRL
  => RowToList params paramRL
  => MakeVars paramRL params
  => Keys paramRL
  => RowToList eqs eqsRL
  => CollectEqs eqsRL eqs
  => (Record state -> Record params -> Record eqs)
  -> SystemSpec state params
system f = SystemSpec
  { eqs: collectEqs (Proxy :: Proxy eqsRL) (f s p)
  , stateVars: keysB (Proxy :: Proxy stateRL)
  , paramVars: keysB (Proxy :: Proxy paramRL)
  }
  where
  s = makeVars :: Record state
  p = makeVars :: Record params

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
compileField (SystemSpec r) =
  compileFieldJ r.stateVars r.paramVars (map (toJExpr <<< snd) r.eqs)

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
