-- | Tier-3 (AlgebraicJulia): a typed **Petri net** surface whose dynamics Julia
-- | derives *functorially*. A `PetriSpec` is pure structure — species, and
-- | transitions with input/output species (multiplicity by repetition) and a
-- | mass-action rate. PureScript never writes a differential equation; it crosses
-- | the seam once as a description, and **AlgebraicPetri** applies the functor
-- | from the category of (open) Petri nets to vector fields — mass-action
-- | kinetics — to produce the ODE system, which OrdinaryDiffEq then solves.
-- |
-- | This is squarely AlgebraicJulia territory: the semantics is a functor, not a
-- | hand-written translation, and (next increment) open nets compose, so a model
-- | built by gluing parts has dynamics that are the composite of the parts'. The
-- | JS/WASM world has no applied-category-theory stack to hand a description to.
module Data.Petri
  ( Transition
  , PetriSpec
  , solve
  , odeLaws
  , writeText
  ) where

import Prelude

import Effect (Effect)

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

foreign import solveJ
  :: Array String
  -> Array String
  -> Array (Array String)
  -> Array (Array String)
  -> Array Number
  -> Array Number
  -> Number
  -> Number
  -> Int
  -> Effect (Array (Array Number))

foreign import odeLawsJ
  :: Array String
  -> Array String
  -> Array (Array String)
  -> Array (Array String)
  -> Effect (Array String)

foreign import writeTextJ :: String -> String -> Effect Unit

-- | Solve the mass-action ODE AlgebraicPetri derives *functorially* from the net,
-- | returning `n + 1` time samples, each `[t, conc₁, …, concₖ]` in species order.
solve :: PetriSpec -> Number -> Number -> Int -> Effect (Array (Array Number))
solve spec t0 t1 n =
  solveJ spec.species (map _.name spec.transitions)
    (map _.inputs spec.transitions) (map _.outputs spec.transitions)
    spec.initial (map _.rate spec.transitions) t0 t1 n

-- | The mass-action ODE laws the functorial semantics implies — one LaTeX string
-- | per species, built Julia-side from the net's stoichiometry (the calculus
-- | PureScript never wrote).
odeLaws :: PetriSpec -> Effect (Array String)
odeLaws spec =
  odeLawsJ spec.species (map _.name spec.transitions)
    (map _.inputs spec.transitions) (map _.outputs spec.transitions)

-- | Write a string to a file (the assembled JSON the page reads).
writeText :: String -> String -> Effect Unit
writeText = writeTextJ
