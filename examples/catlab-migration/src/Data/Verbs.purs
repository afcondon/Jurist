-- | The Catlab-family verb surface, **production denotation**: the same
-- | signature as `Data.Verbs` in `examples/catlab-portable`, but here the
-- | production interpreter exists, so the answer is `Computed` — the real
-- | functorially-migrated graph (module-level backend selection, ADR-0007).
module Data.Verbs
  ( moduleGraph
  ) where

import Prelude

import Data.Answer (Answer(..))
import Data.Migration (CodeGraph)
import Data.Migration.Julia (moduleGraph) as J
import Effect (Effect)

moduleGraph :: CodeGraph -> Effect (Answer (Array (Array Int)))
moduleGraph g = Computed <$> J.moduleGraph g
