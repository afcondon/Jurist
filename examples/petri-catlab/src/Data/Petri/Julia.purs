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
  , vectorField
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

foreign import vectorFieldJ
  :: Array String
  -> Array String
  -> Array (Array String)
  -> Array (Array String)
  -> Array Number
  -> Array Number
  -> Effect (Array Number)

foreign import writeTextJ :: String -> String -> Effect Unit

-- | Solve the mass-action ODE AlgebraicPetri derives *functorially* from the net,
-- | returning `n + 1` time samples, each `[t, conc₁, …, concₖ]` in species order.
solve :: PetriSpec -> Number -> Number -> Int -> Effect (Array (Array Number))
solve spec t0 t1 n =
  solveJ spec.species (map _.name spec.transitions)
    (map _.inputs spec.transitions) (map _.outputs spec.transitions)
    spec.initial (map _.rate spec.transitions) t0 t1 n

-- | The vector field AlgebraicPetri derives from the net, evaluated at one
-- | state: the rate of change of each species, in species order. This is
-- | what `solve` integrates, and what `Data.Petri.massActionRates` is
-- | checked against.
vectorField :: PetriSpec -> Array Number -> Effect (Array Number)
vectorField spec state =
  vectorFieldJ spec.species (map _.name spec.transitions)
    (map _.inputs spec.transitions) (map _.outputs spec.transitions)
    (map _.rate spec.transitions) state

-- | Write a string to a file (the assembled JSON the page reads).
writeText :: String -> String -> Effect Unit
writeText = writeTextJ
