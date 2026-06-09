-- | Tier-2 demo: stage a numeric expression across the seam, compile it to a
-- | native Julia function, and check the compiled result against the pure
-- | PureScript interpreter — a faithful-staging differential check (both run
-- | on Julia here, so any mismatch is a staging bug, not a backend divergence).
module Main where

import Prelude

import Data.Array (elemIndex, index) as Array
import Data.Maybe (fromMaybe)
import Data.NumExpr (NumExpr, compile, evalBatch, eval, num, render, sinE, var)
import Effect (Effect)
import Effect.Console (log)

-- The Lorenz x-RHS plus a transcendental term, written with eDSL ergonomics:
--   10*(y - x) + sin(z)
expr :: NumExpr
expr = num 10.0 * (var "y" - var "x") + sinE (var "z")

vars :: Array String
vars = [ "x", "y", "z" ]

points :: Array (Array Number)
points =
  [ [ 1.0, 2.0, 0.5 ]
  , [ 0.0, 1.0, 1.0 ]
  , [ 3.0, 1.0, 2.0 ]
  , [ -1.0, 4.0, 3.14159 ]
  ]

-- Reference evaluation via the pure interpreter, with positional var lookup.
psEval :: Array Number -> Number
psEval p = eval lookupVar expr
  where
  lookupVar s = fromMaybe 0.0 do
    i <- Array.elemIndex s vars
    Array.index p i

main :: Effect Unit
main = do
  compiled <- compile vars expr
  jl <- evalBatch compiled points
  let ps = map psEval points
  log ("expr:         " <> render expr)
  log ("vars:         " <> show vars)
  log ("PS interp:    " <> show ps)
  log ("Julia native: " <> show jl)
  log ("staging faithful: " <> show (ps == jl))
