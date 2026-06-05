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

-- NOT tail recursive (self-call is an argument of *): must stay plain recursion
fact :: Int -> Int
fact n = case n of
  0 -> 1
  _ -> n * fact (n - 1)

-- mutual recursion: not TCO'd (only self-calls are), stays on the thunk path
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

-- top-level accumulator loop: the canonical TCO target
sumTo :: Int -> Int -> Int
sumTo acc n = case n of
  0 -> acc
  _ -> sumTo (acc + n) (n - 1)

-- local `go` in a where clause: Let-bound Rec, the most common shape in real code
triangle :: Int -> Int
triangle n0 = go 0 n0
  where
  go :: Int -> Int -> Int
  go acc k = case k of
    0 -> acc
    _ -> go (acc + k) (k - 1)

-- tail recursion through pattern guards
collatzSteps :: Int -> Int -> Int
collatzSteps steps n
  | n == 1 = steps
  | mod n 2 == 0 = collatzSteps (steps + 1) (div n 2)
  | otherwise = collatzSteps (steps + 1) (3 * n + 1)

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
  log (show (sumTo 0 1000000))
  log (show (triangle 100000))
  log (show (collatzSteps 0 27))
  log (show probe)

-- closure-capture probe: each iteration's lambda must capture THAT
-- iteration's k (the reason the trampoline calls a loop function per
-- iteration instead of mutating params in place)
chain :: Int -> (Int -> Int) -> Int -> Int
chain k f = case k of
  0 -> f
  _ -> chain (k - 1) (\x -> f x + k)

probe :: Int
probe = chain 3 identity 0
