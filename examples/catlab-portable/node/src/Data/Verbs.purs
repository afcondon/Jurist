-- | The Catlab-family verb surface, **reference denotation**: typed
-- | placeholders. The production interpreters live in the Julia workspaces
-- | (petri-catlab, catlab-patterns, catlab-migration), each of which supplies
-- | a `Data.Verbs` with the same signature wrapping the real Catlab call in
-- | `Computed`. Here the verbs answer `Deferred` with a rendering of the
-- | description they would consume: the host can hold, type-check, display
-- | and pipeline the computation; the answers arrive when the same
-- | description reaches the Julia denotation (ADR-0007).
module Data.Verbs
  ( odeLaws
  , matches
  , moduleGraph
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Array (length)
import Data.Migration (CodeGraph)
import Data.Pattern (Graph, Motif)
import Data.Petri (PetriSpec)
import Effect (Effect)

odeLaws :: PetriSpec -> Effect (Answer (Array String))
odeLaws spec = pure
  ( Deferred
      ( "mass-action ODE laws of the net (" <> show (length spec.species)
          <> " species, " <> show (length spec.transitions)
          <> " transitions), derived functorially — AlgebraicPetri, on the Julia runtime"
      )
  )

matches :: Graph -> Motif -> Effect (Answer (Array (Array Int)))
matches g p = pure
  ( Deferred
      ( "every monic match of “" <> p.name <> "” (" <> p.shape
          <> ") in a graph of " <> show (length g.nodes)
          <> " nodes — Catlab homomorphism search, on the Julia runtime"
      )
  )

moduleGraph :: CodeGraph -> Effect (Answer (Array (Array Int)))
moduleGraph g = pure
  ( Deferred
      ( "Δ migration of " <> show (length g.calls) <> " calls along in_mod onto "
          <> show (length g.modules)
          <> " modules — Catlab ACSets, on the Julia runtime"
      )
  )
