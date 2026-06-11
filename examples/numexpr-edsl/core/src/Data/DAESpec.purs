-- | The pure half of the Tier-2 DAE surface: a row-typed
-- | **differential-algebraic** system description on top of the `NumExpr` eDSL.
-- | Where `SystemSpec` is a pure system of ODEs, a `DAESpec` adds *algebraic
-- | variables* — quantities with no time derivative — and one *algebraic
-- | constraint* per algebraic variable. This is the shape of a constrained
-- | mechanical system: a double pendulum in Cartesian coordinates has positions
-- | and velocities (differential state) plus rod tensions (algebraic), closed by
-- | the rigidity constraints.
-- |
-- | Three rows: `state` (differential), `alg` (algebraic), `params`. The system
-- | is two lambdas:
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
-- | index-1 DAE by construction. This module holds no foreign imports, so the
-- | description compiles on every backend; the Julia denotation
-- | (`Data.DAESystem` in the julia/ workspace) hands it to ModelingToolkit and
-- | an implicit stiff solver. Reuses the RowList machinery from
-- | `Data.SystemSpec` (`MakeVars`, `Keys`, `CollectEqs`) — the DAE surface is
-- | the same row-typed idea with an extra row.
module Data.DAESpec
  ( DAESpec
  , daeSystem
  , stateVars
  , algVars
  , paramVars
  , diffEqs
  , constraints
  ) where

import Prelude

import Data.NumExpr (NumExpr)
import Data.SystemSpec
  ( class CollectEqs
  , class Keys
  , class MakeVars
  , collectEqs
  , keysB
  , makeVarsB
  )
import Data.Tuple (Tuple)
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

-- | The differential equations, one `(stateVar, rhs)` per state variable in row
-- | order — the description handed to a denotation.
diffEqs :: forall s a p. DAESpec s a p -> Array (Tuple String NumExpr)
diffEqs (DAESpec r) = r.diffEqs

-- | The closing constraints, one `(algVar, expr)` per algebraic variable in row
-- | order, each read as `0 ~ expr`.
constraints :: forall s a p. DAESpec s a p -> Array (Tuple String NumExpr)
constraints (DAESpec r) = r.constraints

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
