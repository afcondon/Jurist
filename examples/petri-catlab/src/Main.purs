-- | Tier-3 demo: describe epidemic models as typed Petri nets in PureScript;
-- | AlgebraicPetri derives their mass-action ODEs *functorially* and solves them.
-- | Two nets — SIR and SEIR — share the exact same machinery; only the typed
-- | description differs. The run writes `petri.js` for the `petri-viz/` page,
-- | which draws each net, shows the derived ODE laws (LaTeX), and plots the
-- | trajectory the browser never integrated.
module Main where

import Prelude

import Data.Array (length) as Array
import Data.Petri (PetriSpec, Transition, odeLaws, solve, writeText)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Effect (Effect)
import Effect.Console (log)

-- ── The models (pure typed descriptions) ────────────────────────────────────

sir :: PetriSpec
sir =
  { species: [ "S", "I", "R" ]
  , transitions:
      [ { name: "inf", inputs: [ "S", "I" ], outputs: [ "I", "I" ], rate: 0.0003 }
      , { name: "rec", inputs: [ "I" ], outputs: [ "R" ], rate: 0.1 }
      ]
  , initial: [ 990.0, 10.0, 0.0 ]
  }

-- SEIR adds a latent Exposed compartment between infection and infectiousness.
seir :: PetriSpec
seir =
  { species: [ "S", "E", "I", "R" ]
  , transitions:
      [ { name: "expose", inputs: [ "S", "I" ], outputs: [ "E", "I" ], rate: 0.0004 }
      , { name: "onset", inputs: [ "E" ], outputs: [ "I" ], rate: 0.2 }
      , { name: "recover", inputs: [ "I" ], outputs: [ "R" ], rate: 0.1 }
      ]
  , initial: [ 990.0, 0.0, 10.0, 0.0 ]
  }

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
  laws <- odeLaws spec
  log (title <> ": solved, " <> show (Array.length laws) <> " ODE laws derived functorially")
  pure (itemJson title spec samples laws)

main :: Effect Unit
main = do
  log "== Tier-3: Petri nets → functorial mass-action ODEs (AlgebraicPetri) =="
  itSir <- buildItem "SIR — Susceptible · Infected · Recovered" sir
  itSeir <- buildItem "SEIR — with a latent Exposed compartment" seir
  let json = "{\"items\":" <> jArrRaw [ itSir, itSeir ] <> "}"
  writeText "petri.js" ("window.PETRI = " <> json <> ";\n")
  log "wrote petri.js for the petri-viz page"
