-- | Representation canary — a deliberate, white-box tripwire.
-- |
-- | ADR-0001 fixes how PureScript values are encoded as Julia values, and
-- | ADR-0002 acknowledges that the port is irreducibly bound to that encoding
-- | (the "constructors across" rule decouples user-shim *authoring* from the
-- | shape, but the efficiency goal forbids a fully representation-agnostic
-- | FFI). This module pins the encoding: each `foreign import` hands a
-- | compiled PS value to a Julia shim that asserts its *raw shape* and
-- | `Base.error`s on any drift. If `purejl` ever changes how it encodes
-- | ADTs / records / newtypes / Effect / Array, this example fails loudly
-- | (non-zero exit) instead of letting hand-written shims break silently.
-- |
-- | This is a conformance guard, not a usage demo.
module Main where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)

newtype Wrapped = Wrapped Int

-- Each returns "ok" or aborts the run from the Julia side on a shape mismatch.
foreign import checkJust :: Maybe Int -> String
foreign import checkNothing :: Maybe Int -> String
foreign import checkRecord :: { a :: Int, b :: Int } -> String
foreign import checkNewtypeErased :: Wrapped -> Int -> String
foreign import checkEffectThunk :: Effect Unit -> String
foreign import checkArrayVector :: Array Int -> String

main :: Effect Unit
main = do
  log ("repr-maybe-just:     " <> checkJust (Just 7))
  log ("repr-maybe-nothing:  " <> checkNothing Nothing)
  log ("repr-record-dict:    " <> checkRecord { a: 1, b: 2 })
  log ("repr-newtype-erased: " <> checkNewtypeErased (Wrapped 42) 42)
  log ("repr-effect-thunk:   " <> checkEffectThunk (pure unit))
  log ("repr-array-vector:   " <> checkArrayVector [ 10, 20, 30 ])
  log "repr-canary: all representation contracts hold"
