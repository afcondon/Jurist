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
-- | lambda builds a `NumExpr` AST. The state/param rows flow through
-- | `SystemSpec → integrate`, so initial conditions and parameters must match
-- | the system by type, and the alphabetical RowList order is used consistently
-- | on both sides (no positional mixups).
-- |
-- | This module is **backend-agnostic** — it holds no `foreign import`s, so the
-- | description *and its pure-PureScript denotation* (`integratePure`, a RK4 in
-- | plain PureScript) compile on any backend (JS/Node, the BEAM, purejl). The
-- | Julia *production* denotation — compiling the vector field to a native RHS
-- | and integrating it with a native RK4 (or, in the sibling modules, MTK /
-- | DAEs) — lives in the companion `Data.SystemSpec.Julia`. One description,
-- | two denotations (ADR-0007).
module Data.SystemSpec
  ( SystemSpec
  , system
  , stateVars
  , paramVars
  , equations
  , integratePure
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

import Data.Array (elemIndex, index, range, scanl, zipWith, (:))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.NumExpr (NumExpr, eval, var)
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.Tuple (Tuple(..), snd)
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

-- | The **develop-anywhere** denotation of the *same* `SystemSpec`: a pure
-- | PureScript RK4 that reads the system's `NumExpr` equations and evaluates
-- | them with the reference interpreter (`Data.NumExpr.eval`) — no FFI, so it
-- | runs on any backend (JS/Node, the BEAM, …), not just Julia. It is the
-- | dummy/prototyping executor to the production executor `Data.SystemSpec.Julia.integrate`:
-- | one description, two denotations (ADR-0007). The RK4 step order matches the
-- | Julia `integrateJ` exactly, so on a non-chaotic horizon the two agree to
-- | machine precision (the `julia/` and `node/` `Main`s each cross-check it).
-- |
-- | It is pure (no `Effect`) — the computation has no side effects; only the
-- | Julia handle-based path needs `Effect`.
integratePure
  :: forall state stateRL stateN stateNRL params paramRL paramN paramNRL
   . RowToList state stateRL
  => NumberRow stateRL stateN
  => RowToList stateN stateNRL
  => ToValues stateNRL stateN
  => RowToList params paramRL
  => NumberRow paramRL paramN
  => RowToList paramN paramNRL
  => ToValues paramNRL paramN
  => SystemSpec state params
  -> Record stateN
  -> Record paramN
  -> Number
  -> Int
  -> Array (Array Number)
integratePure (SystemSpec sys) s0 ps dt steps =
  scanl (\st _ -> rk4Step st) s0arr (range 1 steps)
  where
  s0arr = toValuesB (Proxy :: Proxy stateNRL) s0
  psarr = toValuesB (Proxy :: Proxy paramNRL) ps
  rhsExprs = map snd sys.eqs

  -- Look a variable up by name: state vars index into the current state, param
  -- vars into the (constant) parameter vector — the binding the fused Julia RGF
  -- does positionally, done here by name.
  envFor st name = case elemIndex name sys.stateVars of
    Just i -> fromMaybe 0.0 (index st i)
    Nothing -> case elemIndex name sys.paramVars of
      Just j -> fromMaybe 0.0 (index psarr j)
      Nothing -> 0.0

  rhs st = map (\e -> eval (envFor st) e) rhsExprs

  -- One RK4 step; combine ordered exactly as integrateJ's
  -- `k1 .+ 2 .*k2 .+ 2 .*k3 .+ k4` (left-assoc) so the arithmetic matches.
  rk4Step st =
    let
      k1 = rhs st
      k2 = rhs (vadd st (vscale (dt / 2.0) k1))
      k3 = rhs (vadd st (vscale (dt / 2.0) k2))
      k4 = rhs (vadd st (vscale dt k3))
      comb = vadd (vadd (vadd k1 (vscale 2.0 k2)) (vscale 2.0 k3)) k4
    in
      vadd st (vscale (dt / 6.0) comb)

  vadd = zipWith (+)
  vscale k = map (k * _)
