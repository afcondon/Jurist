-- | A typed **Petri net** surface. A `PetriSpec` is pure structure: species,
-- | and transitions with input and output species (multiplicity by
-- | repetition) and a mass-action rate. Nobody writes a differential
-- | equation into one.
-- |
-- | Two things are read off that structure here, in plain PureScript on any
-- | backend: the mass-action laws as text (`massActionLaws`) and as numbers
-- | (`massActionRates`). On Julia, **AlgebraicPetri** derives the same
-- | dynamics by its functor from Petri nets to vector fields, and
-- | OrdinaryDiffEq solves that; `examples/petri-catlab` checks the reading
-- | here against the library's vector field at every state it solves.
-- |
-- | This module has no foreign imports. The Julia denotation lives in
-- | `Data.Petri.Julia` in the parent workspace.
module Data.Petri
  ( Transition
  , PetriSpec
  , massActionLaws
  , massActionRates
  ) where

import Prelude

import Data.Array (filter, group, length, sort, zip)
import Data.Array.NonEmpty as NonEmpty
import Data.Foldable (product, sum)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith, stripPrefix)
import Data.String.Pattern (Pattern(..))
import Data.Tuple (Tuple(..))

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

-- How many of a species a transition makes, less how many it consumes.
netChange :: String -> Transition -> Int
netChange species transition = count transition.outputs - count transition.inputs
  where
  count = length <<< filter (_ == species)

-- | One law per species, in `species` order, as LaTeX: the rate of change
-- | of its concentration under mass-action kinetics. Each transition
-- | contributes its rate constant times the concentrations of its inputs,
-- | once for every unit of the species it makes or consumes.
massActionLaws :: PetriSpec -> Array String
massActionLaws spec = map law spec.species
  where
  law species = "\\frac{d" <> species <> "}{dt} = " <> body species

  body species = case filter (\(Tuple change _) -> change /= 0) (contributions species) of
    [] -> "0"
    terms ->
      let
        written = joinWith " " (map term terms)
      in
        fromMaybe written (stripPrefix (Pattern "+ ") written)

  contributions species = map (\transition -> Tuple (netChange species transition) transition) spec.transitions

  term (Tuple change transition) =
    (if change > 0 then "+ " else "- ")
      <> (if magnitude change == 1 then "" else show (magnitude change) <> " ")
      <> flux transition

  magnitude n = if n < 0 then negate n else n

  -- The rate constant, then each input species once, with its multiplicity
  -- as a power, in alphabetical order.
  flux transition =
    joinWith " \\, "
      ( [ "\\mathrm{" <> transition.name <> "}" ]
          <> map power (group (sort transition.inputs))
      )

  power occurrences = case NonEmpty.length occurrences of
    1 -> NonEmpty.head occurrences
    n -> NonEmpty.head occurrences <> "^{" <> show n <> "}"

-- | The same laws as numbers: the rate of change of each species, in
-- | `species` order, at the given concentrations (also in `species` order).
massActionRates :: PetriSpec -> Array Number -> Array Number
massActionRates spec concentrations = map rate spec.species
  where
  rate species = sum (map (contribution species) spec.transitions)

  contribution species transition =
    toNumber (netChange species transition) * transition.rate * product (map concentration transition.inputs)

  concentration species = fromMaybe 0.0 (lookup species)

  lookup species = case filter (\(Tuple name _) -> name == species) (zip spec.species concentrations) of
    [ Tuple _ value ] -> Just value
    _ -> Nothing
