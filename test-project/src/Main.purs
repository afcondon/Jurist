module Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)

data Shape
  = Circle Number
  | Rect Number Number
  | Point

newtype Name = Name String

area :: Shape -> Number
area = case _ of
  Circle r -> 3.14159265 * r * r
  Rect w h -> w * h
  Point -> 0.0

describe :: Shape -> String
describe s
  | area s > 10.0 = "big"
  | otherwise = "small"

greet :: Name -> String
greet (Name n) = "Hello, " <> n

fact :: Int -> Int
fact n = case n of
  0 -> 1
  _ -> n * fact (n - 1)

isEven :: Int -> Boolean
isEven n = case n of
  0 -> true
  _ -> isOdd (n - 1)

isOdd :: Int -> Boolean
isOdd n = case n of
  0 -> false
  _ -> isEven (n - 1)

type Person = { name :: String, age :: Int }

birthday :: Person -> Person
birthday p = p { age = p.age + 1 }

main :: Effect Unit
main = do
  log "Hello from PureScript, via Julia!"
  log (show (area (Circle 2.0)))
  log (describe (Rect 4.0 3.0))
  log (greet (Name "Hylograph"))
  log (show (fact 10))
  log (show (isEven 42))
  log (show (map (_ * 2) [ 1, 2, 3 ]))
  let alice = { name: "Alice", age: 41 }
  log (show (birthday alice).age)
  log (show (compare 1 2))
