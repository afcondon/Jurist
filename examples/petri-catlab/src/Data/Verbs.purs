-- | The Catlab-family verb surface on Julia: the same signature as
-- | `Data.Verbs` in `examples/catlab-portable`.
-- |
-- | `odeLaws` is read off the net by `Data.Petri.massActionLaws`, which is
-- | plain PureScript, so it is `Computed` here and on every other runtime.
-- | (Until November 2026 it was built by a Julia foreign file and presented
-- | as something only Julia could answer. It never was.)
module Data.Verbs
  ( odeLaws
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Petri (PetriSpec, massActionLaws)
import Effect (Effect)

odeLaws :: PetriSpec -> Effect (Answer (Array String))
odeLaws spec = pure (Computed (massActionLaws spec))
