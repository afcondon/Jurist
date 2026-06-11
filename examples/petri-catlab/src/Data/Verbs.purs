-- | The Catlab-family verb surface, **production denotation**: the same
-- | signature as `Data.Verbs` in `examples/catlab-portable`, but here the
-- | production interpreter exists, so the answer is `Computed` — the real
-- | functorially-derived ODE laws (module-level backend selection, ADR-0007).
module Data.Verbs
  ( odeLaws
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Petri (PetriSpec)
import Data.Petri.Julia (odeLaws) as J
import Effect (Effect)

odeLaws :: PetriSpec -> Effect (Answer (Array String))
odeLaws spec = Computed <$> J.odeLaws spec
