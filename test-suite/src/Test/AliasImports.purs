-- | Calls through an alias whose target lives in a module this one does not
-- | import.
-- |
-- | Added 2026-11-19. `Data.Nullable.toNullable` is defined as
-- | `maybe null notNull`: a top-level name applied to top-level names. A
-- | backend that looks through such an alias (purs's "expander"; ADR-0010 in
-- | Jurist) emits the call here as a call of `Data.Maybe.maybe`, and so names
-- | `Data.Maybe` in a module whose source never imported it. Jurist's oracle
-- | lane emitted that name without the import, and the module failed to load.
-- |
-- | The corpus did not catch it because every module that called
-- | `toNullable` also happened to import `Data.Maybe`. So this module must
-- | NOT import `Data.Maybe`, directly or through an instance: no `Maybe`
-- | constructor, no `show`, `map` or `==` at a `Maybe` type. The `Maybe`
-- | values come from `Data.Array` and are consumed by `toNullable` alone.
module Test.AliasImports where

import Prelude

import Data.Array as Array
import Data.Nullable (toNullable)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t label value = log ("TEST " <> label <> ": " <> value)

main :: Effect Unit
main = do
  t "alias-unimported-target-eq"
    (show (toNullable (Array.head [ 41 ]) == toNullable (Array.head [ 41 ])))
  t "alias-unimported-target-neq"
    (show (toNullable (Array.head [ 41 ]) == toNullable (Array.last [ 41, 42 ])))
  t "alias-unimported-target-null"
    (show (toNullable (Array.head ([] :: Array Int)) == toNullable (Array.head [ 41 ])))
