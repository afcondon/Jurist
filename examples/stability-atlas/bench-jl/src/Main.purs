-- | Size comes from argv so one build serves both measurement points, and the
-- | difference between them cancels startup cost.
module Main where

import Prelude

import Atlas.Bench (benchSteps, largeSize, smallSize)
import Effect (Effect)
import Effect.Console (log)

foreign import wantLarge :: Effect Boolean

main :: Effect Unit
main = do
  large <- wantLarge
  log (show (benchSteps (if large then largeSize else smallSize)))
