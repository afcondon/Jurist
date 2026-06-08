-- | Tier-1 demo: typed Julia handles under the ST region discipline.
-- |
-- | The whole computation runs inside `ST.run`, so the `STNumberVector`
-- | handles never escape; only the frozen `Array Number` results do. On
-- | this backend those handles are real `Vector{Float64}`s and the ops are
-- | BLAS calls — but to PureScript it is just pure `ST`.
module Main where

import Prelude

import Control.Monad.ST (run) as ST
import Data.STNumberVector as V
import Effect (Effect)
import Effect.Console (log)

type Result =
  { dotXY :: Number       -- inner product of the originals
  , normY :: Number       -- L2 norm after y := 2x + y
  , halfY :: Array Number  -- 0.5 * (2x + y)
  , clamped :: Array Number -- previous, clamped into [8, 20]
  }

-- | Pure to PureScript; BLAS-effectful inside the region.
demo :: Result
demo = ST.run do
  x <- V.thaw [ 1.0, 2.0, 3.0, 4.0 ]
  y <- V.thaw [ 10.0, 20.0, 30.0, 40.0 ]
  d <- V.dot x y                 -- 10 + 40 + 90 + 160 = 300
  V.axpy 2.0 x y                 -- y := 2x + y = [12, 24, 36, 48]
  n <- V.normL2 y
  V.scale 0.5 y                  -- y := [6, 12, 18, 24]
  halfY <- V.freeze y
  V.clampV 8.0 20.0 y            -- y := [8, 12, 18, 20]
  clamped <- V.freeze y
  pure { dotXY: d, normY: n, halfY, clamped }

main :: Effect Unit
main = do
  log ("dot x y       = " <> show demo.dotXY)
  log ("normL2 (2x+y) = " <> show demo.normY)
  log ("0.5*(2x+y)    = " <> show demo.halfY)
  log ("clamp 8 20    = " <> show demo.clamped)
