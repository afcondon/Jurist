-- | The dimensioned-quantity demo: a spring–bob period computed in a typed
-- | language whose **types do the dimensional analysis**, then handed to
-- | DynamicQuantities for the runtime half — SI rendering, unit conversion,
-- | and an independent re-check of what the compiler already proved.
-- |
-- | Two layers of the same guarantee:
-- |  * compile time (any backend, browser included): exponent arithmetic in
-- |    the type system — a mis-dimensioned expression does not build;
-- |  * runtime (Julia): DynamicQuantities enforces the same algebra on
-- |    whatever reaches it, including requests it can only check dynamically
-- |    (like converting a period to metres — see the last receipt).
module Main where

import Prelude

import Data.Number (pi)
import Data.Quantity (Quantity, kilograms, newtonsPerMeter, qSqrt, scalar, value, (|*|), (|/|))
import Data.Quantity.Julia (inUnits, prettySI)
import Effect (Effect)
import Effect.Console (log)

-- A spring of 5.2 N/m: mass¹ · time⁻² — the dimension is the type.
springK :: Quantity 1 0 (-2)
springK = newtonsPerMeter 5.2

bobMass :: Quantity 1 0 0
bobMass = kilograms 0.35

-- | T = 2π·√(m/k). The division subtracts exponents (kg / (kg·s⁻²) = s²),
-- | the square root halves them, and the annotation pins the result: this
-- | only compiles because the dimensional algebra works out to time¹.
period :: Quantity 0 0 1
period = scalar (2.0 * pi) |*| qSqrt (bobMass |/| springK)

-- The line that does NOT compile — adding a spring constant to a mass.
-- Captured verbatim from purs 0.15:
--
--   nonsense = springK |+| bobMass
--
--   [ERROR] TypesDoNotUnify
--     Could not match type 0 with type -2
--     while trying to match type Quantity 1 0 0
--       with type Quantity 1 0 -2
--
-- On every other stack this is a runtime DimensionError at best, a silently
-- wrong number at worst. Here it is rejected before the program exists.

main :: Effect Unit
main = do
  log "== typed dimensions: the PureScript types did the dimensional analysis =="
  log ("period, raw value:        " <> show (value period))
  si <- prettySI period
  log ("rendered by Julia (SI):   " <> si)
  ms <- inUnits "ms" period
  log ("converted to ms:          " <> ms)
  mins <- inUnits "min" period
  log ("converted to min:         " <> mins)
  -- The runtime half of the guarantee: a conversion the type system never
  -- sees (the target unit is a runtime string) is still refused, with
  -- DynamicQuantities' own error, honestly relayed.
  bad <- inUnits "m" period
  log ("converted to m:           " <> bad)
