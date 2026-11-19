-- | `Data.Argonaut.Core` and `Data.Argonaut.Parser`: JSON values, printed
-- | and parsed.
-- |
-- | Added 2026-11-19, with the shims that let Glassbox's codec run on a
-- | backend other than JavaScript. On JS these two modules are
-- | `JSON.stringify` and `JSON.parse`; elsewhere they are a printer and a
-- | parser that must agree with those to the byte, because the printed text
-- | is what crosses between runtimes.
-- |
-- | Parse FAILURES are tested only as failures. The message is the engine's
-- | own (V8 and JavaScriptCore word them differently), so no test prints one.
module Test.Json where

import Prelude

import Data.Argonaut.Core (Json, caseJson, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify, stringifyWithIndent)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..), either)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Foreign.Object as Object

t :: String -> String -> Effect Unit
t label value = log ("TEST " <> label <> ": " <> value)

obj :: Array (Tuple String Json) -> Json
obj = fromObject <<< Object.fromFoldable

kind :: Json -> String
kind = caseJson
  (const "null")
  (\b -> "boolean " <> show b)
  (\n -> "number " <> show n)
  (\s -> "string " <> show s)
  (\a -> "array of " <> show (map kind a))
  (\o -> "object with " <> show (Object.keys o))

-- Parse, then print again: the round trip is the claim.
reprint :: String -> String
reprint = either (const "PARSE FAILED") stringify <<< jsonParser

fails :: String -> String
fails s = case jsonParser s of
  Left _ -> "rejected"
  Right j -> "ACCEPTED as " <> stringify j

nested :: Json
nested = obj
  [ Tuple "name" (fromString "glassbox")
  , Tuple "version" (fromNumber 1.0)
  , Tuple "tags" (fromArray [ fromString "a", jsonNull, fromBoolean true ])
  , Tuple "empty" (obj [])
  , Tuple "none" (fromArray [])
  , Tuple "inner" (obj [ Tuple "z" (fromNumber 0.5), Tuple "a" (fromBoolean false) ])
  ]

main :: Effect Unit
main = do
  -- printing scalars
  t "json-null" (stringify jsonNull)
  t "json-booleans" (stringify (fromArray [ fromBoolean true, fromBoolean false ]))
  t "json-string" (stringify (fromString "plain"))
  t "json-string-empty" (stringify (fromString ""))

  -- numbers print as JS prints them
  t "json-number-integral" (stringify (fromNumber 42.0))
  t "json-number-fraction" (stringify (fromNumber 0.1))
  t "json-number-negative" (stringify (fromNumber (-3.25)))
  t "json-number-zero" (stringify (fromNumber 0.0))
  t "json-number-negzero" (stringify (fromNumber (-0.0)))
  t "json-number-large" (stringify (fromNumber 1.0e21))
  t "json-number-just-below-large" (stringify (fromNumber 123456789012345680000.0))
  t "json-number-small" (stringify (fromNumber 1.0e-7))
  t "json-number-just-above-small" (stringify (fromNumber 0.000001))
  t "json-number-max-safe" (stringify (fromNumber 9007199254740991.0))
  t "json-number-nan-is-null" (stringify (fromNumber (0.0 / 0.0)))
  t "json-number-infinity-is-null" (stringify (fromArray [ fromNumber (1.0 / 0.0), fromNumber (-1.0 / 0.0) ]))

  -- string escapes: the short forms, \u00xx for the other controls, and
  -- nothing else (a slash, a DEL and non-ASCII text are written as they are)
  t "json-escape-quote-backslash" (stringify (fromString "say \"hi\" \\ bye"))
  t "json-escape-short-forms" (stringify (fromString "a\nb\tc\rd"))
  t "json-escape-control" (stringify (fromString "bell\x07 esc\x1b nul\x00 unit\x1f"))
  t "json-escape-backspace-formfeed" (stringify (fromString "\x08\x0c"))
  t "json-no-escape-slash-del" (stringify (fromString "a/b\x7f"))
  t "json-no-escape-unicode" (stringify (fromString "café — naïve"))

  -- structure
  t "json-array-empty" (stringify (fromArray []))
  t "json-object-empty" (stringify (obj []))
  t "json-nested" (stringify nested)
  t "json-object-key-order-is-insertion"
    (stringify (obj [ Tuple "zebra" jsonNull, Tuple "apple" jsonNull, Tuple "mango" jsonNull ]))
  t "json-object-index-keys-first"
    (stringify (obj [ Tuple "b" jsonNull, Tuple "10" jsonNull, Tuple "9" jsonNull ]))
  t "json-key-escaped" (stringify (obj [ Tuple "a\"b\n" jsonNull ]))

  -- indentation
  t "json-indent-2" (stringifyWithIndent 2 nested)
  t "json-indent-0-is-compact" (stringifyWithIndent 0 nested)
  t "json-indent-clamped-at-10"
    (stringifyWithIndent 40 (fromArray [ jsonNull ]))
  t "json-indent-empties-stay-closed"
    (stringifyWithIndent 2 (fromArray [ fromArray [], obj [] ]))
  t "json-indent-scalar" (stringifyWithIndent 2 (fromNumber 1.5))

  -- case analysis
  t "json-kind-null" (kind jsonNull)
  t "json-kind-boolean" (kind (fromBoolean false))
  t "json-kind-number" (kind (fromNumber 2.5))
  t "json-kind-string" (kind (fromString "s"))
  t "json-kind-array" (kind (fromArray [ jsonNull, fromNumber 1.0 ]))
  t "json-kind-object" (kind nested)

  -- parsing: what comes back prints as JS would print it
  t "json-parse-scalars" (reprint " [null, true, false, 0, -1, 2.50, 1e3, 1E-2, \"s\"] ")
  t "json-parse-kinds" (either (const "PARSE FAILED") kind (jsonParser "[null,true,1,\"s\",[],{}]"))
  t "json-parse-whitespace" (reprint "\n\t{ \"a\" :\r[ 1 ,2 ] , \"b\":{ } }\n")
  t "json-parse-keeps-key-order" (reprint "{\"zebra\":1,\"apple\":2,\"mango\":3}")
  t "json-parse-index-keys-first" (reprint "{\"b\":1,\"10\":2,\"9\":3}")
  t "json-parse-duplicate-key" (reprint "{\"a\":1,\"b\":2,\"a\":3}")
  t "json-parse-escapes" (reprint "\"\\\" \\\\ \\/ \\b \\f \\n \\r \\t\"")
  t "json-parse-unicode-escape" (reprint "\"caf\\u00e9 \\u0041\\u000a\"")
  t "json-parse-nested-deep" (reprint "[[[[[[{\"k\":[{}]}]]]]]]")
  t "json-parse-number-forms" (reprint "[0.0, -0, 10, 1.5e2, 123456789012345678901234567890, 5e-324]")
  t "json-parse-top-level-scalar" (reprint "  42  ")
  t "json-roundtrip-nested" (reprint (stringify nested))
  t "json-roundtrip-indented" (reprint (stringifyWithIndent 4 nested))

  -- parsing: what JSON does not allow
  t "json-reject-empty" (fails "")
  t "json-reject-whitespace-only" (fails "   ")
  t "json-reject-trailing-comma-array" (fails "[1,2,]")
  t "json-reject-trailing-comma-object" (fails "{\"a\":1,}")
  t "json-reject-leading-zero" (fails "01")
  t "json-reject-bare-minus" (fails "-")
  t "json-reject-dot-without-digits" (fails "1.")
  t "json-reject-leading-dot" (fails ".5")
  t "json-reject-plus" (fails "+1")
  t "json-reject-exponent-without-digits" (fails "1e")
  t "json-reject-single-quotes" (fails "'a'")
  t "json-reject-unquoted-key" (fails "{a:1}")
  t "json-reject-unterminated-string" (fails "\"abc")
  t "json-reject-unterminated-array" (fails "[1,2")
  t "json-reject-raw-newline-in-string" (fails "\"a\nb\"")
  t "json-reject-bad-escape" (fails "\"\\x41\"")
  t "json-reject-short-unicode-escape" (fails "\"\\u12\"")
  t "json-reject-trailing-text" (fails "{} x")
  t "json-reject-two-values" (fails "1 2")
  t "json-reject-nan" (fails "NaN")
  t "json-reject-undefined" (fails "undefined")
  t "json-reject-truncated-literal" (fails "tru")
  t "json-reject-comment" (fails "[1] // one")

  -- ordering: null < boolean < number < string < array < object
  let
    ladder =
      [ jsonNull, fromBoolean false, fromBoolean true, fromNumber (-1.0), fromNumber 2.0
      , fromString "a", fromString "b", fromArray [], fromArray [ jsonNull ]
      , fromArray [ jsonNull, jsonNull ], obj [], obj [ Tuple "a" jsonNull ]
      ]
  t "json-compare-ladder" (show (map (\j -> map (compare j) ladder) ladder))
  t "json-eq" (show [ nested == nested, nested == jsonNull, fromNumber 1.0 == fromNumber 1.0 ])
  t "json-eq-object-ignores-key-order"
    (show (obj [ Tuple "a" jsonNull, Tuple "b" (fromNumber 1.0) ] == obj [ Tuple "b" (fromNumber 1.0), Tuple "a" jsonNull ]))
  t "json-compare-objects-by-sorted-key"
    (show (compare (obj [ Tuple "b" (fromNumber 1.0), Tuple "a" (fromNumber 2.0) ]) (obj [ Tuple "a" (fromNumber 1.0), Tuple "b" (fromNumber 2.0) ])))
