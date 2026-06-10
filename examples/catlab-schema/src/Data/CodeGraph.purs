-- | Tier-3 (Catlab / ACSets): a **typed multi-sort schema**, not just a graph.
-- | The schema has two object sorts — `Module` and `Func` — and a typed morphism
-- | `in_mod : Func → Module`, plus `Call` with `src`/`tgt : Call → Func`. An
-- | instance is a typed code graph; a *motif* is a small instance of the same
-- | schema, and the motif's own type structure **encodes the constraint**: a
-- | motif with two *distinct* pattern-modules matches only cross-module calls;
-- | one with a shared pattern-module matches intra-module structure.
-- |
-- | This is the ACSet payoff — a typed schema language for graph-shaped data,
-- | the categorical analogue of Hylograph's typed graphs. PureScript describes
-- | the schema instance and the motifs; Catlab's homomorphism search finds every
-- | occurrence. It is the machinery a Minard could use to express and check
-- | architectural rules (cross-module coupling, shared dependencies, layering).
module Data.CodeGraph
  ( Edge
  , Func
  , CodeGraph
  , Motif
  , Match
  , matches
  , writeText
  ) where

import Prelude

import Data.Array (drop, length, take)
import Effect (Effect)

type Edge = { from :: Int, to :: Int }

-- | A function: its name and the index of the `Module` it belongs to (`in_mod`).
type Func = { name :: String, inMod :: Int }

-- | A typed code graph: module names, functions typed into modules, and calls
-- | (edges between function indices).
type CodeGraph = { modules :: Array String, funcs :: Array Func, calls :: Array Edge }

-- | A typed motif over the same schema: anonymous modules (by count) and
-- | functions (each typed into a pattern-module by `fnMod`), with calls. The
-- | module structure carries the architectural constraint.
type Motif =
  { name :: String, shape :: String, nMod :: Int, fnMod :: Array Int, calls :: Array Edge }

-- | One occurrence: the graph-function and graph-module indices the motif mapped
-- | onto (0-based).
type Match = { funcs :: Array Int, mods :: Array Int }

foreign import matchesJ
  :: Int
  -> Array Int
  -> Array Int
  -> Array Int
  -> Int
  -> Array Int
  -> Array Int
  -> Array Int
  -> Effect (Array (Array Int))

foreign import writeTextJ :: String -> String -> Effect Unit

-- | Every injective match of `motif` in `graph`. Each raw result is the motif's
-- | function map followed by its module map; we split it back into a `Match`.
matches :: CodeGraph -> Motif -> Effect (Array Match)
matches g m = do
  raw <- matchesJ (length g.modules) (map _.inMod g.funcs)
    (map _.from g.calls) (map _.to g.calls)
    m.nMod m.fnMod (map _.from m.calls) (map _.to m.calls)
  let nF = length m.fnMod
  pure (map (\r -> { funcs: take nF r, mods: drop nF r }) raw)

writeText :: String -> String -> Effect Unit
writeText = writeTextJ
