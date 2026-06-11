-- | The Catlab-family verb surface, **production denotation**: the same
-- | signature as `Data.Verbs` in `examples/catlab-portable`, but here the
-- | production interpreter exists, so the answer is `Computed` — the real
-- | homomorphism matches (module-level backend selection, ADR-0007).
module Data.Verbs
  ( matches
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Pattern (Graph, Motif)
import Data.Pattern.Julia (matches) as J
import Effect (Effect)

matches :: Graph -> Motif -> Effect (Answer (Array (Array Int)))
matches g p = Computed <$> J.matches g p
