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
foreign import checkRecordBits :: { p :: { x :: Number, y :: Number }, m :: Number } -> String
foreign import checkSameType :: forall a. a -> a -> String
foreign import checkNewtypeErased :: Wrapped -> Int -> String
foreign import checkEffectThunk :: Effect Unit -> String
foreign import checkArrayVector :: Array Int -> String

-- A record whose closure captures the record before it. If a record kept
-- the type of every field, this one's type would be as deep as the chain,
-- and Julia would compile a specialisation per depth (ADR-0012).
type Step = { depth :: Int, rest :: Unit -> Int }

grow :: Step -> Step
grow s = { depth: s.depth + 1, rest: \_ -> s.depth + s.rest unit }

growN :: Int -> Step -> Step
growN n s = if n <= 0 then s else growN (n - 1) (grow s)

-- The same record written at top level, with its fields in another order,
-- and built inside a function. A top-level literal is built by a different
-- runtime path (`_ps_rec_dyn`), and the two must come out as one type.
topRecord :: { a :: Int, b :: Int }
topRecord = { b: 2, a: 1 }

inFunction :: Int -> { a :: Int, b :: Int }
inFunction n = { a: n, b: 2 }

base :: Step
base = { depth: 0, rest: \_ -> 0 }

main :: Effect Unit
main = do
  log ("repr-maybe-just:     " <> checkJust (Just 7))
  log ("repr-maybe-nothing:  " <> checkNothing Nothing)
  log ("repr-record-dict:    " <> checkRecord { a: 1, b: 2 })
  log ("repr-record-bits:    " <> checkRecordBits { p: { x: 1.0, y: 2.0 }, m: 3.0 })
  log ("repr-record-depth:   " <> checkSameType (growN 1 base) (growN 50 base))
  log ("repr-record-toplevel:" <> " " <> checkSameType topRecord (inFunction 1))
  log ("repr-newtype-erased: " <> checkNewtypeErased (Wrapped 42) 42)
  log ("repr-effect-thunk:   " <> checkEffectThunk (pure unit))
  log ("repr-array-vector:   " <> checkArrayVector [ 10, 20, 30 ])
  log "repr-canary: all representation contracts hold"
