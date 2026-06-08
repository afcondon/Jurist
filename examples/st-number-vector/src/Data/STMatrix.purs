-- | Tier-1 typed handles, matrices: `STMatrix h` is a real Julia
-- | `Matrix{Float64}` (column-major, LAPACK/BLAS-ready), the natural
-- | companion to `Data.STNumberVector`. Same region discipline — the handle
-- | is opaque and cannot escape `ST.run`; `freeze` is the only path back to
-- | PureScript values.
-- |
-- | Representation independence: results that are PureScript *ADTs* (`Maybe`)
-- | or *records* are never built by hardcoding the backend's runtime
-- | encoding. The shim is handed the constructors / record-builder — which,
-- | post-compilation, are ordinary Julia closures living in the Julia
-- | runtime — and calls them. The whole factorization still completes in one
-- | go on Julia; only the irreducible primitive contracts (Number↔Float64,
-- | Array↔Vector, ST↔thunk) and handed-in functions cross the seam.
-- | "Constructors across, handles back."
module Data.STMatrix
  ( STMatrix
  , LU
  , new
  , identityMatrix
  , fromRows
  , freeze
  , rows
  , cols
  , scaleM
  , transpose
  , mulMV
  , mul
  , det
  , solve
  , lu
  , cholesky
  ) where

import Prelude

import Control.Monad.ST (ST)
import Control.Monad.ST.Internal (Region)
import Data.Maybe (Maybe(..))
import Data.STNumberVector (STNumberVector)

-- | A mutable `Matrix{Float64}` owned by Julia, scoped to region `h`.
foreign import data STMatrix :: Region -> Type

-- | Allocate a zero-filled `rows × cols` matrix.
foreign import new :: forall h. Int -> Int -> ST h (STMatrix h)

-- | The `n × n` identity.
foreign import identityMatrix :: forall h. Int -> ST h (STMatrix h)

-- | Build from row-major nested arrays (each inner array is a row).
foreign import fromRows :: forall h. Array (Array Number) -> ST h (STMatrix h)

-- | Materialize back to row-major nested arrays — the only path into
-- | PureScript-land.
foreign import freeze :: forall h. STMatrix h -> ST h (Array (Array Number))

foreign import rows :: forall h. STMatrix h -> ST h Int
foreign import cols :: forall h. STMatrix h -> ST h Int

-- | Fused kernel: `a := alpha * a` in place.
foreign import scaleM :: forall h. Number -> STMatrix h -> ST h Unit

-- | A fresh transposed matrix.
foreign import transpose :: forall h. STMatrix h -> ST h (STMatrix h)

-- | Matrix·vector product (fresh result vector).
foreign import mulMV :: forall h. STMatrix h -> STNumberVector h -> ST h (STNumberVector h)

-- | Matrix·matrix product (fresh result matrix).
foreign import mul :: forall h. STMatrix h -> STMatrix h -> ST h (STMatrix h)

-- | Determinant (LU-based).
foreign import det :: forall h. STMatrix h -> ST h Number

-- | Solve `a · x = b` for `x` (LAPACK `\`).
foreign import solve :: forall h. STMatrix h -> STNumberVector h -> ST h (STNumberVector h)

-- | LU factorization with partial pivoting. `p` is the 0-based row
-- | permutation.
type LU h = { l :: STMatrix h, u :: STMatrix h, p :: Array Int }

-- | The shim never constructs the record's runtime shape: it is handed
-- | `\l u p -> { l, u, p }` (a compiled Julia closure) and calls it.
lu :: forall h. STMatrix h -> ST h (LU h)
lu = luImpl (\l u p -> { l, u, p })

foreign import luImpl
  :: forall h
   . (STMatrix h -> STMatrix h -> Array Int -> LU h)
  -> STMatrix h
  -> ST h (LU h)

-- | `cholesky a` returns the upper Cholesky factor `R` (with `Rᵀ R = a`)
-- | when `a` is symmetric positive-definite, else `Nothing`. A successful
-- | factorization *is* the positive-definiteness evidence — the Tier-1 seed
-- | of the proof-carrying-handle idea (a future `Checked PosDef`).
-- |
-- | `Just`/`Nothing` are passed into the shim as constructors, never
-- | hardcoded as tag-tuples.
cholesky :: forall h. STMatrix h -> ST h (Maybe (STMatrix h))
cholesky = choleskyImpl Just Nothing

foreign import choleskyImpl
  :: forall h
   . (STMatrix h -> Maybe (STMatrix h))
  -> Maybe (STMatrix h)
  -> STMatrix h
  -> ST h (Maybe (STMatrix h))
