module Loop where

import Prelude
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref

-- A counted Effect loop over a Ref. No library, no allocation beyond the Ref:
-- the smallest thing that still exercises the whole representation -- curried
-- closures, Effect-as-thunk, and a foreign Ref.
countTo :: Int -> Effect Int
countTo n = do
  r <- Ref.new 0
  let
    go i
      | i >= n = Ref.read r
      | otherwise = Ref.modify_ (_ + 1) r *> go (i + 1)
  go 0

main :: Effect Unit
main = do
  a <- countTo 1000
  log ("warm " <> show a)
