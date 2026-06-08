-- | Tier-1 of the "Julia-shaped libraries" doctrine (*descriptions across,
-- | handles back*): a mutable numeric vector that lives in Julia as a real
-- | `Vector{Float64}` — contiguous, BLAS-ready — never as the `Vector{Any}`
-- | the generic `Data.Array.ST` shim produces.
-- |
-- | The handle `STNumberVector h` is opaque and region-scoped. The rank-2
-- | boundary `ST.run :: (forall h. ST h a) -> a` guarantees no handle
-- | escapes, so the only way data crosses back into PureScript is an
-- | explicit `freeze`. Every operation Julia does natively (`axpy`, `dot`,
-- | `scale`, `normL2`) is a *single* FFI call over the whole vector — the
-- | hot loop never crosses the seam, so BLAS / the specializer see
-- | contiguous Float64 memory.
-- |
-- | Note the deliberate absence of `mapNum :: (Number -> Number) -> ...`:
-- | a PureScript closure per element is the callback anti-pattern in
-- | miniature (opaque to the specializer, curried-Dict glue per call).
-- | Instead we expose a *vocabulary of fused kernels* (`scale`, `offset`,
-- | `expV`, `clampV`); the general case is the Tier-2 `NumExpr` eDSL, which
-- | stages an expression across the seam *once*, not a closure per element.
module Data.STNumberVector
  ( STNumberVector
  , new
  , thaw
  , freeze
  , length
  , read
  , write
  , dot
  , axpy
  , scale
  , offset
  , expV
  , clampV
  , sumNum
  , normL2
  ) where

import Prelude

import Control.Monad.ST (ST)
import Control.Monad.ST.Internal (Region)

-- | A mutable `Vector{Float64}` owned by Julia, scoped to region `h`.
foreign import data STNumberVector :: Region -> Type

-- | Allocate a zero-filled vector of length `n`.
foreign import new :: forall h. Int -> ST h (STNumberVector h)

-- | Copy a PureScript `Array Number` into a fresh `Vector{Float64}`.
foreign import thaw :: forall h. Array Number -> ST h (STNumberVector h)

-- | The explicit materialization: copy the handle out to `Array Number`.
-- | This is the *only* path by which values cross back into PureScript.
foreign import freeze :: forall h. STNumberVector h -> ST h (Array Number)

foreign import length :: forall h. STNumberVector h -> ST h Int

-- | 0-based read (the FFI translates to Julia's 1-based indexing).
foreign import read :: forall h. STNumberVector h -> Int -> ST h Number

-- | 0-based write.
foreign import write :: forall h. STNumberVector h -> Int -> Number -> ST h Unit

-- | `dot x y` — BLAS inner product.
foreign import dot :: forall h. STNumberVector h -> STNumberVector h -> ST h Number

-- | `axpy a x y` — in place `y := a*x + y` (BLAS `axpy!`).
foreign import axpy :: forall h. Number -> STNumberVector h -> STNumberVector h -> ST h Unit

-- | Fused kernel: `x := a*x` in place.
foreign import scale :: forall h. Number -> STNumberVector h -> ST h Unit

-- | Fused kernel: `x := x + c` (broadcast-add a scalar) in place.
foreign import offset :: forall h. Number -> STNumberVector h -> ST h Unit

-- | Fused kernel: `x := exp.(x)` in place.
foreign import expV :: forall h. STNumberVector h -> ST h Unit

-- | Fused kernel: clamp every element into `[lo, hi]` in place.
foreign import clampV :: forall h. Number -> Number -> STNumberVector h -> ST h Unit

foreign import sumNum :: forall h. STNumberVector h -> ST h Number

-- | L2 / Euclidean norm (BLAS `nrm2`).
foreign import normL2 :: forall h. STNumberVector h -> ST h Number
