-- | A typed language for dimensioned quantities where the **dimension lives in
-- | the type**: `Quantity mass length time` carries the three exponents as
-- | `Prim.Int` type-level integers. Velocity is `Quantity 0 1 (-1)`, force is
-- | `Quantity 1 1 (-2)`, and `meters 1.0 |+| seconds 2.0` is not a runtime
-- | `DimensionError` — it **does not compile**, on any backend, browser
-- | included.
-- |
-- | The arithmetic *is* the dimensional algebra: multiplication adds exponents
-- | (`Prim.Int.Add`, solved by the compiler), division subtracts them (Add's
-- | three-way functional dependencies give subtraction for free), and square
-- | root halves them (`Mul 2 half whole` — `Mul`'s single fundep means the
-- | result type must be pinned by annotation or context, which in practice it
-- | always is).
-- |
-- | The exponents cross to the runtime via `Data.Reflectable` (compiler-solved,
-- | so it works on every backend): `exponents` hands the dimension over as a
-- | plain record — exactly the value-level representation the Julia denotation
-- | (DynamicQuantities, `Data.Quantity.Julia`) consumes for rendering, unit
-- | conversion, and an independent runtime re-check of what the types already
-- | proved.
module Data.Quantity
  ( Quantity
  , scalar
  , kilograms
  , grams
  , meters
  , seconds
  , metersPerSecond
  , newtons
  , newtonsPerMeter
  , value
  , exponents
  , qAdd
  , (|+|)
  , qSub
  , (|-|)
  , qMul
  , (|*|)
  , qDiv
  , (|/|)
  , qSqrt
  ) where

import Prelude

import Data.Number (sqrt)
import Data.Reflectable (class Reflectable, reflectType)
import Prim.Int (class Add, class Mul)
import Type.Proxy (Proxy(..))

-- | A `Number` whose physical dimension — exponents of mass, length, time —
-- | is part of its type. The constructor is not exported; build values with
-- | the dimensioned constructors below.
newtype Quantity (mass :: Int) (length :: Int) (time :: Int) = Quantity Number

-- | The bare number (dimension forgotten — use at the edge, not in the middle).
value :: forall m l t. Quantity m l t -> Number
value (Quantity x) = x

-- | The dimension, reflected from the type to a plain record — the value-level
-- | currency the Julia denotation consumes.
exponents
  :: forall m l t
   . Reflectable m Int
  => Reflectable l Int
  => Reflectable t Int
  => Quantity m l t
  -> { mass :: Int, length :: Int, time :: Int }
exponents _ =
  { mass: reflectType (Proxy :: Proxy m)
  , length: reflectType (Proxy :: Proxy l)
  , time: reflectType (Proxy :: Proxy t)
  }

scalar :: Number -> Quantity 0 0 0
scalar = Quantity

kilograms :: Number -> Quantity 1 0 0
kilograms = Quantity

-- | Grams enter as kilograms — SI base units at the boundary, like
-- | DynamicQuantities' `u"..."` does.
grams :: Number -> Quantity 1 0 0
grams g = Quantity (g / 1000.0)

meters :: Number -> Quantity 0 1 0
meters = Quantity

seconds :: Number -> Quantity 0 0 1
seconds = Quantity

metersPerSecond :: Number -> Quantity 0 1 (-1)
metersPerSecond = Quantity

newtons :: Number -> Quantity 1 1 (-2)
newtons = Quantity

newtonsPerMeter :: Number -> Quantity 1 0 (-2)
newtonsPerMeter = Quantity

-- | Addition demands the SAME dimension — the type system refuses `m + s`.
qAdd :: forall m l t. Quantity m l t -> Quantity m l t -> Quantity m l t
qAdd (Quantity a) (Quantity b) = Quantity (a + b)

infixl 6 qAdd as |+|

qSub :: forall m l t. Quantity m l t -> Quantity m l t -> Quantity m l t
qSub (Quantity a) (Quantity b) = Quantity (a - b)

infixl 6 qSub as |-|

-- | Multiplication adds dimension exponents, in the type, at compile time.
qMul
  :: forall m1 l1 t1 m2 l2 t2 m3 l3 t3
   . Add m1 m2 m3
  => Add l1 l2 l3
  => Add t1 t2 t3
  => Quantity m1 l1 t1
  -> Quantity m2 l2 t2
  -> Quantity m3 l3 t3
qMul (Quantity a) (Quantity b) = Quantity (a * b)

infixl 7 qMul as |*|

-- | Division subtracts exponents — `Add m2 m3 m1` read backwards through its
-- | functional dependencies.
qDiv
  :: forall m1 l1 t1 m2 l2 t2 m3 l3 t3
   . Add m2 m3 m1
  => Add l2 l3 l1
  => Add t2 t3 t1
  => Quantity m1 l1 t1
  -> Quantity m2 l2 t2
  -> Quantity m3 l3 t3
qDiv (Quantity a) (Quantity b) = Quantity (a / b)

infixl 7 qDiv as |/|

-- | Square root halves the exponents: `Mul 2 half whole` pins
-- | `half · 2 = whole`. `Mul`'s fundep only computes left-to-right, so the
-- | result dimension must be fixed by an annotation or the surrounding
-- | context — `√(s²)` annotated as seconds compiles; `√(s)` cannot be given
-- | integer exponents and is rejected.
qSqrt
  :: forall m l t mh lh th
   . Mul 2 mh m
  => Mul 2 lh l
  => Mul 2 th t
  => Quantity m l t
  -> Quantity mh lh th
qSqrt (Quantity x) = Quantity (sqrt x)
