-- | `Foreign.Object`: a JavaScript object seen from PureScript.
-- |
-- | Added 2026-11-19, with the shims that let Glassbox's codec run on a
-- | backend other than JavaScript. What makes it worth a module of its own
-- | is ORDER. A JS object enumerates its keys in a defined order, and
-- | `keys`, `values`, `toUnfoldable`, `fold` and the key order of
-- | `JSON.stringify` all show it: keys that are array indices ("0", "7",
-- | "42") first, ascending numerically, then every other key in the order
-- | it was first inserted. Assigning to an existing key keeps its place;
-- | deleting and re-inserting moves it to the end. A backend that models
-- | an object as an unordered map gets every lookup right and every listing
-- | wrong, and nothing but a listing shows it.
module Test.ForeignObjects where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Foreign.Object (Object)
import Foreign.Object as Object

t :: String -> String -> Effect Unit
t label value = log ("TEST " <> label <> ": " <> value)

-- Deliberately not alphabetical, so sorted order and insertion order differ.
zebra :: Object Int
zebra = Object.empty
  # Object.insert "zebra" 1
  # Object.insert "apple" 2
  # Object.insert "mango" 3

listing :: Object Int -> String
listing o = show (Object.toUnfoldable o :: Array (Tuple String Int))

main :: Effect Unit
main = do
  t "obj-empty-size" (show (Object.size (Object.empty :: Object Int)))
  t "obj-empty-isEmpty" (show (Object.isEmpty (Object.empty :: Object Int)))
  t "obj-singleton" (listing (Object.singleton "k" 7))
  t "obj-size" (show (Object.size zebra))
  t "obj-lookup-present" (show (Object.lookup "apple" zebra))
  t "obj-lookup-absent" (show (Object.lookup "pear" zebra))
  t "obj-member" (show [ Object.member "zebra" zebra, Object.member "pear" zebra ])

  -- order: first insertion, not sorted
  t "obj-keys-insertion-order" (show (Object.keys zebra))
  t "obj-values-insertion-order" (show (Object.values zebra))
  t "obj-toUnfoldable-order" (listing zebra)
  t "obj-toAscUnfoldable-sorted" (show (Object.toAscUnfoldable zebra :: Array (Tuple String Int)))

  -- overwriting keeps the key's place; delete and re-insert moves it last
  t "obj-overwrite-keeps-place" (listing (Object.insert "zebra" 9 zebra))
  t "obj-delete" (listing (Object.delete "apple" zebra))
  t "obj-delete-absent" (listing (Object.delete "pear" zebra))
  t "obj-delete-reinsert-moves-last"
    (listing (Object.insert "zebra" 9 (Object.delete "zebra" zebra)))

  -- array-index keys come first, in NUMERIC order, whatever the insertion order
  let
    mixed = Object.empty
      # Object.insert "b" 1
      # Object.insert "10" 2
      # Object.insert "a" 3
      # Object.insert "9" 4
      # Object.insert "0" 5
  t "obj-index-keys-first-numeric" (show (Object.keys mixed))
  -- "01" and "-1" and "1.5" are not array indices: they keep insertion order
  let
    nearly = Object.empty
      # Object.insert "x" 1
      # Object.insert "01" 2
      # Object.insert "-1" 3
      # Object.insert "1.5" 4
      # Object.insert "2" 5
  t "obj-non-canonical-numbers-not-indices" (show (Object.keys nearly))
  -- the largest array index is 2^32 - 2; 2^32 - 1 is an ordinary key
  let
    edge = Object.empty
      # Object.insert "4294967295" 1
      # Object.insert "k" 2
      # Object.insert "4294967294" 3
  t "obj-index-upper-bound" (show (Object.keys edge))

  -- every traversal goes in that same order
  t "obj-fold-order" (Object.fold (\acc k v -> acc <> k <> "=" <> show v <> ";") "" zebra)
  t "obj-foldMap-order" (Object.foldMap (\k v -> [ k <> show v ]) zebra # show)
  t "obj-foldl-values" (show (foldl (\acc v -> acc * 10 + v) 0 zebra))
  t "obj-map" (listing (map (_ * 100) zebra))
  t "obj-mapWithKey" (show (Object.toUnfoldable (Object.mapWithKey (\k v -> k <> show v) zebra) :: Array (Tuple String String)))
  t "obj-all" (show [ Object.all (\_ v -> v > 0) zebra, Object.all (\_ v -> v > 1) zebra ])
  t "obj-filter" (listing (Object.filter (_ > 1) zebra))
  t "obj-filterKeys" (listing (Object.filterKeys (_ /= "apple") zebra))

  -- building and combining
  let pairs = [ Tuple "q" 1, Tuple "c" 2, Tuple "q" 3, Tuple "a" 4 ]
  t "obj-fromFoldable-last-wins-first-place" (listing (Object.fromFoldable pairs))
  t "obj-fromFoldableWith" (listing (Object.fromFoldableWith (+) pairs))
  t "obj-union-left-biased"
    (listing (Object.union (Object.fromFoldable [ Tuple "m" 1, Tuple "z" 2 ]) zebra))
  t "obj-unionWith"
    (listing (Object.unionWith (+) (Object.fromFoldable [ Tuple "m" 10, Tuple "z" 20 ]) zebra))
  t "obj-alter-insert" (listing (Object.alter (const (Just 5)) "new" zebra))
  t "obj-alter-delete" (listing (Object.alter (const Nothing) "apple" zebra))
  t "obj-update" (listing (Object.update (\v -> Just (v + 1)) "mango" zebra))
  t "obj-pop" (show (map (\(Tuple v o) -> Tuple v (Object.keys o)) (Object.pop "apple" zebra)))

  -- an Object is immutable: none of the above changed `zebra`
  t "obj-original-untouched" (listing zebra)
  t "obj-empty-untouched" (show (Object.size (Object.empty :: Object Int)))

  -- instances
  t "obj-eq" (show [ zebra == zebra, zebra == Object.delete "apple" zebra ])
  t "obj-eq-ignores-order"
    (show (Object.fromFoldable [ Tuple "a" 1, Tuple "b" 2 ] == Object.fromFoldable [ Tuple "b" 2, Tuple "a" 1 ]))
  t "obj-show" (show zebra)
  t "obj-semigroup" (show (Object.keys (map (\v -> [ v ]) zebra <> Object.singleton "apple" [ 99 ])))
  t "obj-keys-sorted-by-hand" (show (Array.sort (Object.keys zebra)))
