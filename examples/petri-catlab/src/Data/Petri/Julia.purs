-- | The **Julia denotation** of the Petri-net surface: the description (from
-- | core's `Data.Petri`) crosses the seam once as plain arrays, and
-- | **AlgebraicPetri** applies the functor from the category of (open) Petri
-- | nets to vector fields — mass-action kinetics — to produce the ODE system,
-- | which OrdinaryDiffEq then solves. The semantics is a functor, not a
-- | hand-written translation, and (next increment) open nets compose, so a
-- | model built by gluing parts has dynamics that are the composite of the
-- | parts'.
module Data.Petri.Julia
  ( solve
  , odeLaws
  , writeText
  ) where

import Prelude

import Data.Petri (PetriSpec)
import Effect (Effect)

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
