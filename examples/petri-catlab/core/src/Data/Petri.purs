-- | Tier-3 (AlgebraicJulia): a typed **Petri net** surface whose dynamics Julia
-- | derives *functorially*. A `PetriSpec` is pure structure — species, and
-- | transitions with input/output species (multiplicity by repetition) and a
-- | mass-action rate. PureScript never writes a differential equation; it crosses
-- | the seam once as a description, and **AlgebraicPetri** applies the functor
-- | from the category of (open) Petri nets to vector fields — mass-action
-- | kinetics — to produce the ODE system, which OrdinaryDiffEq then solves.
-- |
-- | This module is the pure description language only (no foreign imports); the
-- | Julia denotation lives in `Data.Petri.Julia` in the parent workspace, and
-- | the portable `Deferred` denotation in `examples/catlab-portable`.
module Data.Petri
  ( Transition
  , PetriSpec
  ) where

-- | A named reaction: input and output species (a species repeated = higher
-- | multiplicity) and a mass-action rate constant.
type Transition =
  { name :: String, inputs :: Array String, outputs :: Array String, rate :: Number }

-- | A Petri net: species, transitions, and one initial concentration per species
-- | (in `species` order).
type PetriSpec =
  { species :: Array String
  , transitions :: Array Transition
  , initial :: Array Number
  }
