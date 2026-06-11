-- | Tier-3 (Catlab / ACSets): **functorial data migration**. The other ACSet
-- | superpower beside homomorphism search — transform structured data *along a
-- | schema mapping*, with categorical guarantees. A Δ (pullback) migration
-- | aggregates a function-level call graph **up** to a module dependency graph
-- | along the `in_mod` functor: every call `f → g` becomes a module edge
-- | `in_mod(f) → in_mod(g)`. Not a hand-written fold — a migration functor.
-- |
-- | This module is the pure description language only (no foreign imports); the
-- | Julia denotation lives in `Data.Migration.Julia` in the parent workspace,
-- | and the portable `Deferred` denotation in `examples/catlab-portable`.
module Data.Migration
  ( Edge
  , Func
  , CodeGraph
  ) where

type Edge = { from :: Int, to :: Int }

-- | A function: its name and the index of the `Module` it belongs to (`in_mod`).
type Func = { name :: String, inMod :: Int }

-- | A typed code graph: module names, functions typed into modules, and calls
-- | (edges between function indices).
type CodeGraph = { modules :: Array String, funcs :: Array Func, calls :: Array Edge }
