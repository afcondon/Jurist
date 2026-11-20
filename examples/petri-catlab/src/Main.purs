-- | Tier-3 demo: describe epidemic models as typed Petri nets in PureScript;
-- | AlgebraicPetri derives their mass-action dynamics *functorially* and
-- | OrdinaryDiffEq solves them. Two nets — SIR and SEIR — share the exact
-- | same machinery; only the typed description differs.
-- |
-- | The laws the page typesets are written out by `Data.Petri`, in plain
-- | PureScript, and are not the library's output. So this program checks
-- | them against it: at every state the solver returns, the rates those laws
-- | give must match the vector field AlgebraicPetri derived.
-- |
-- | The run writes `petri.js` for the `petri-viz/` page, which draws each
-- | net, shows the laws, and plots the trajectory the browser never
-- | integrated.
module Main where

import Prelude

import Data.Answer (describe)
import Data.Array (all, drop, filter, length, zipWith) as Array
import Data.Number (abs)
import Data.Petri (PetriSpec, Transition, massActionLaws, massActionRates)
import Data.Petri.Julia (solve, vectorField, writeText)
import Data.Petri.Models (seir, sir)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.Verbs (odeLaws) as V
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)

-- ── Minimal JSON encoding (LaTeX is backslash-heavy: escape \ first, then ") ──

jStr :: String -> String
jStr s = "\"" <> esc s <> "\""
  where
  esc =
    replaceAll (Pattern "\"") (Replacement "\\\"")
      <<< replaceAll (Pattern "\\") (Replacement "\\\\")

jArrStr :: Array String -> String
jArrStr xs = "[" <> joinWith "," (map jStr xs) <> "]"

jNumArr :: Array Number -> String
jNumArr xs = "[" <> joinWith "," (map show xs) <> "]"

jNumArr2 :: Array (Array Number) -> String
jNumArr2 xs = "[" <> joinWith "," (map jNumArr xs) <> "]"

jArrRaw :: Array String -> String
jArrRaw xs = "[" <> joinWith "," xs <> "]"

transitionJson :: Transition -> String
transitionJson t =
  "{\"name\":" <> jStr t.name
    <> ",\"inputs\":" <> jArrStr t.inputs
    <> ",\"outputs\":" <> jArrStr t.outputs
    <> ",\"rate\":" <> show t.rate
    <> "}"

itemJson :: String -> PetriSpec -> Array (Array Number) -> Array String -> String
itemJson title spec samples laws =
  "{\"title\":" <> jStr title
    <> ",\"species\":" <> jArrStr spec.species
    <> ",\"transitions\":" <> jArrRaw (map transitionJson spec.transitions)
    <> ",\"initial\":" <> jNumArr spec.initial
    <> ",\"laws\":" <> jArrStr laws
    <> ",\"samples\":" <> jNumArr2 samples
    <> "}"

buildItem :: String -> PetriSpec -> Effect String
buildItem title spec = do
  samples <- solve spec 0.0 200.0 200
  let
    laws = massActionLaws spec
    states = map (Array.drop 1) samples
  derived <- traverse (vectorField spec) states
  let agreeing = Array.length (Array.filter identity (Array.zipWith sameRates (map (massActionRates spec) states) derived))
  log (title <> ": solved, " <> show (Array.length laws) <> " mass-action laws")
  log ("  the laws as written give AlgebraicPetri's vector field at "
    <> show agreeing <> " of " <> show (Array.length states) <> " solved states")
  pure (itemJson title spec samples laws)

-- Equal to within rounding: the two sum the same products in a different
-- order.
sameRates :: Array Number -> Array Number -> Boolean
sameRates mine theirs =
  Array.length mine == Array.length theirs
    && Array.all identity (Array.zipWith (\a b -> abs (a - b) <= 1.0e-9 * (1.0 + abs b)) mine theirs)

main :: Effect Unit
main = do
  log "== Tier-3: Petri nets → functorial mass-action dynamics (AlgebraicPetri) =="
  itSir <- buildItem "SIR — Susceptible · Infected · Recovered" sir
  itSeir <- buildItem "SEIR — with a latent Exposed compartment" seir
  let json = "{\"items\":" <> jArrRaw [ itSir, itSeir ] <> "}"
  writeText "petri.js" ("window.PETRI = " <> json <> ";\n")
  log "wrote petri.js for the petri-viz page"

  -- The verb surface: the same call, with the same answer, on every runtime.
  log "\n== the verb surface: this runtime's answer =="
  vLaws <- V.odeLaws sir
  log ("odeLaws sir: " <> describe (joinWith "   ") vLaws)
