-- | The **Julia denotation** of the typed Quantity language: the dimension
-- | exponents (reflected from the type by `Data.Quantity.exponents`) and the
-- | value cross the seam as plain numbers; DynamicQuantities rebuilds the
-- | quantity, renders it, converts it, and — independently of the PureScript
-- | type system — enforces the same dimensional algebra at runtime.
module Data.Quantity.Julia
  ( prettySI
  , inUnits
  ) where

import Prelude

import Data.Quantity (Quantity, exponents, value)
import Data.Reflectable (class Reflectable)
import Effect (Effect)

foreign import prettySIJ :: Number -> Int -> Int -> Int -> Effect String

foreign import inUnitsJ :: String -> Number -> Int -> Int -> Int -> Effect String

-- | The quantity as DynamicQuantities renders it in SI: value and unit.
prettySI
  :: forall m l t
   . Reflectable m Int
  => Reflectable l Int
  => Reflectable t Int
  => Quantity m l t
  -> Effect String
prettySI q = prettySIJ (value q) e.mass e.length e.time
  where
  e = exponents q

-- | The quantity converted to the requested unit (parsed at runtime by
-- | DynamicQuantities), or — if the dimensions don't match — the runtime's
-- | own refusal, verbatim. The types prevent this branch for expressions
-- | built in PureScript; the runtime check covers everything else.
inUnits
  :: forall m l t
   . Reflectable m Int
  => Reflectable l Int
  => Reflectable t Int
  => String
  -> Quantity m l t
  -> Effect String
inUnits target q = inUnitsJ target (value q) e.mass e.length e.time
  where
  e = exponents q
