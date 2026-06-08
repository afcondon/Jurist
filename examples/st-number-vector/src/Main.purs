-- | Tier-1 demo: typed Julia handles under the ST region discipline.
-- |
-- | The whole computation runs inside `ST.run`, so the `STNumberVector` /
-- | `STMatrix` handles never escape; only the frozen `Array Number` /
-- | `Array (Array Number)` results (and a `Boolean`) do. On this backend
-- | those handles are real `Vector{Float64}` / `Matrix{Float64}` and the ops
-- | are BLAS/LAPACK calls — but to PureScript it is just pure `ST`.
module Main where

import Prelude

import Control.Monad.ST (run) as ST
import Data.Maybe (Maybe(..), isNothing)
import Data.STMatrix as M
import Data.STNumberVector as V
import Effect (Effect)
import Effect.Console (log)

type VecResult =
  { dotXY :: Number       -- inner product of the originals
  , normY :: Number       -- L2 norm after y := 2x + y
  , halfY :: Array Number  -- 0.5 * (2x + y)
  , clamped :: Array Number -- previous, clamped into [8, 20]
  }

vecDemo :: VecResult
vecDemo = ST.run do
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

type MatResult =
  { ax :: Array Number             -- A · x
  , detA :: Number                 -- det A
  , sol :: Array Number            -- A \ b
  , cholU :: Array (Array Number)  -- upper Cholesky factor of a PD matrix
  , indefIsNothing :: Boolean      -- cholesky of an indefinite matrix → Nothing
  , luU :: Array (Array Number)    -- U factor from LU
  }

matDemo :: MatResult
matDemo = ST.run do
  a <- M.fromRows [ [ 4.0, 1.0 ], [ 1.0, 3.0 ] ]      -- symmetric positive-definite
  x <- V.thaw [ 1.0, 2.0 ]
  ax <- M.mulMV a x >>= V.freeze                      -- [6, 7]
  d <- M.det a                                        -- 11
  b <- V.thaw [ 1.0, 2.0 ]
  sol <- M.solve a b >>= V.freeze                     -- A⁻¹ b
  cholU <- M.cholesky a >>= case _ of
    Just r -> M.freeze r
    Nothing -> pure []
  notPd <- M.fromRows [ [ 1.0, 2.0 ], [ 2.0, 1.0 ] ]  -- indefinite (eigs 3, -1)
  indef <- M.cholesky notPd
  luRes <- M.lu a
  luU <- M.freeze luRes.u
  pure
    { ax
    , detA: d
    , sol
    , cholU
    , indefIsNothing: isNothing indef
    , luU
    }

main :: Effect Unit
main = do
  log "== vectors =="
  log ("dot x y       = " <> show vecDemo.dotXY)
  log ("normL2 (2x+y) = " <> show vecDemo.normY)
  log ("0.5*(2x+y)    = " <> show vecDemo.halfY)
  log ("clamp 8 20    = " <> show vecDemo.clamped)
  log "== matrices =="
  log ("A*x           = " <> show matDemo.ax)
  log ("det A         = " <> show matDemo.detA)
  log ("A \\ b         = " <> show matDemo.sol)
  log ("cholesky U    = " <> show matDemo.cholU)
  log ("indefinite?   = Nothing: " <> show matDemo.indefIsNothing)
  log ("lu U          = " <> show matDemo.luU)
