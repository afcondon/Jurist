module Main where

import Prelude

import Control.Monad.ST as ST
import Control.Monad.ST.Ref as Ref
import Data.Array as Array
import Data.Array.ST as STA
import Data.Enum (fromEnum, toEnum)
import Data.Foldable (foldl, foldr, foldMap, sum)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..))
import Data.String as Str
import Data.String.CodeUnits as SCU
import Data.Traversable (traverse, sequence)
import Data.Tuple (Tuple(..))
import Data.Unfoldable (replicate, unfoldr)
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
  -- arrays
  log (show (Array.range 1 5))
  log (show (Array.index [ 10, 20, 30 ] 1))
  log (show (Array.uncons [ 1, 2, 3 ]))
  log (show (Array.sort [ 3, 1, 2 ]))
  log (show (Array.filter (_ > 2) [ 1, 2, 3, 4 ]))
  log (show (Array.zipWith (+) [ 1, 2, 3 ] [ 10, 20, 30 ]))
  log (show (Array.reverse (Array.range 1 5)))
  log (show (Array.concat [ [ 1, 2 ], [ 3 ], [ 4, 5 ] ]))
  log (show (Array.insertAt 1 99 [ 1, 2, 3 ]))
  log (show (Array.updateAt 0 7 [ 1, 2, 3 ]))
  log (show (Array.deleteAt 1 [ 1, 2, 3 ]))
  log (show (Array.findIndex (_ == 3) [ 1, 2, 3 ]))
  log (show (Array.slice 1 3 [ 0, 1, 2, 3, 4 ]))
  log (show (Array.take 2 [ 1, 2, 3 ]))
  log (show (Array.drop 2 [ 1, 2, 3 ]))
  log (show (Array.partition (_ > 2) [ 1, 2, 3, 4 ]))
  log (show (Array.mapWithIndex (\i x -> i + x) [ 10, 20, 30 ]))
  log (show (Array.scanl (+) 0 [ 1, 2, 3, 4 ]))
  log (show (Array.nub [ 1, 2, 1, 3, 2 ]))
  -- foldable / traversable
  log (show (sum [ 1.0, 2.0, 3.0 ]))
  log (show (foldr (-) 0 [ 1, 2, 3 ]))
  log (show (foldl (-) 0 [ 1, 2, 3 ]))
  log (foldMap show [ 1, 2, 3 ])
  log (show (traverse (\x -> if x > 0 then Just x else Nothing) [ 1, 2, 3 ]))
  log (show (traverse (\x -> if x > 1 then Just x else Nothing) [ 1, 2, 3 ]))
  log (show (sequence [ Just 1, Just 2 ]))
  -- strings
  log (Str.toUpper "hello, julia")
  log (show (Str.split (Pattern ",") "a,b,c"))
  log (Str.joinWith "-" [ "x", "y", "z" ])
  log (show (Str.length "hello"))
  log (show (Str.indexOf (Pattern "ll") "hello"))
  log (Str.replace (Pattern "l") (Replacement "L") "hello")
  log (Str.replaceAll (Pattern "l") (Replacement "L") "hello")
  log (Str.trim "  padded  ")
  log (Str.take 4 "purescript")
  log (Str.drop 4 "purescript")
  log (show (SCU.toCharArray "abc"))
  log (SCU.fromCharArray [ 'J', 'l' ])
  log (show (SCU.charAt 1 "abc"))
  log (show (Str.contains (Pattern "scri") "purescript"))
  -- ST
  log (show (sortViaST [ 3, 1, 2 ]))
  log (show stSum)
  log (show stWhile)
  -- ints
  log (Int.toStringAs Int.hexadecimal 255)
  log (show (Int.fromString "42"))
  log (show (Int.fromString "nope"))
  log (show (Int.quot (-7) 2))
  log (show (Int.rem (-7) 2))
  log (show (Int.pow 2 10))
  log (show (Int.toNumber 5))
  log (show (Int.floor 3.7))
  log (show (Int.round 3.5))
  -- unfoldable / enum
  log (show (replicate 3 'x' :: Array Char))
  log (show (unfoldr (\n -> if n > 5 then Nothing else Just (Tuple n (n + 1))) 1 :: Array Int))
  log (show (fromEnum 'A'))
  log (show ((toEnum 66) :: Maybe Char))

-- ST with a mutable array: push, in-place sort, freeze
sortViaST :: Array Int -> Array Int
sortViaST input = ST.run do
  arr <- STA.thaw input
  _ <- STA.push 0 arr
  _ <- STA.sort arr
  STA.freeze arr

-- STRef accumulator via ST.for (exercises for_, new, modify, read)
stSum :: Int
stSum = ST.run do
  ref <- Ref.new 0
  ST.for 1 11 (\i -> Ref.modify (_ + i) ref)
  Ref.read ref

-- ST.while loop (exercises while_ and map_)
stWhile :: Int
stWhile = ST.run do
  ref <- Ref.new 0
  ST.while ((_ < 100) <$> Ref.read ref) (void (Ref.modify (_ + 7) ref))
  Ref.read ref

-- closure-capture probe: each iteration's lambda must capture THAT
-- iteration's k (the reason the trampoline calls a loop function per
-- iteration instead of mutating params in place)
chain :: Int -> (Int -> Int) -> Int -> Int
chain k f = case k of
  0 -> f
  _ -> chain (k - 1) (\x -> f x + k)

probe :: Int
probe = chain 3 identity 0
