-- | A minimal, dependency-free JSON ADT with printer and parser, in pure
-- | PureScript. This is the canonical wire syntax for the atlas protocol:
-- | both ends of the WebSocket print and parse with THIS module, compiled
-- | to their respective backends.
-- |
-- | Scope: the parser accepts the printer's output language (a canonical
-- | JSON subset). Specifically: string escapes are limited to
-- | \\ \" \n \t \r \/ \b \f — no \uXXXX escapes (the printer never emits
-- | them; non-ASCII crosses the wire as raw UTF-8). Numbers must be finite.
module Atlas.Json
  ( Json(..)
  , printJson
  , parseJson
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String (joinWith)
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))

data Json
  = JNull
  | JBool Boolean
  | JNum Number
  | JStr String
  | JArr (Array Json)
  | JObj (Array (Tuple String Json))

-- | Compact canonical rendering. Object fields print in the order given —
-- | codecs construct them in declaration order, so both backends emit
-- | byte-identical text for equal values (the differential-test property).
printJson :: Json -> String
printJson = case _ of
  JNull -> "null"
  JBool true -> "true"
  JBool false -> "false"
  JNum n -> show n
  JStr s -> printString s
  JArr xs -> "[" <> joinWith "," (map printJson xs) <> "]"
  JObj kvs -> "{" <> joinWith "," (map printField kvs) <> "}"
  where
  printField :: Tuple String Json -> String
  printField (Tuple k v) = printString k <> ":" <> printJson v

printString :: String -> String
printString s = "\"" <> joinWith "" (map escapeChar (CU.toCharArray s)) <> "\""
  where
  escapeChar :: Char -> String
  escapeChar = case _ of
    '\\' -> "\\\\"
    '"' -> "\\\""
    '\n' -> "\\n"
    '\t' -> "\\t"
    '\r' -> "\\r"
    c -> CU.singleton c

-- | Parse the canonical subset. Errors carry the code-unit position.
parseJson :: String -> Either String Json
parseJson input = do
  Tuple v rest <- pValue (skipWs 0)
  let end = skipWs rest
  if end >= CU.length input then Right v
  else Left ("trailing input at position " <> show end)
  where
  peek :: Int -> Maybe Char
  peek i = CU.charAt i input

  err :: forall a. String -> Int -> Either String a
  err msg i = Left (msg <> " at position " <> show i)

  skipWs :: Int -> Int
  skipWs i = case peek i of
    Just c | c == ' ' || c == '\n' || c == '\t' || c == '\r' -> skipWs (i + 1)
    _ -> i

  pValue :: Int -> Either String (Tuple Json Int)
  pValue i = case peek i of
    Nothing -> err "unexpected end of input" i
    Just '{' -> pObject (skipWs (i + 1)) Nil
    Just '[' -> pArray (skipWs (i + 1)) Nil
    Just '"' -> do
      Tuple s j <- pString (i + 1) Nil
      Right (Tuple (JStr s) j)
    Just 't' -> pLiteral "true" (JBool true) i
    Just 'f' -> pLiteral "false" (JBool false) i
    Just 'n' -> pLiteral "null" JNull i
    Just _ -> pNumber i

  pLiteral :: String -> Json -> Int -> Either String (Tuple Json Int)
  pLiteral word v i =
    let n = CU.length word in
    if CU.slice i (i + n) input == word then Right (Tuple v (i + n))
    else err ("expected " <> word) i

  isNumChar :: Char -> Boolean
  isNumChar c =
    (c >= '0' && c <= '9')
      || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'

  pNumber :: Int -> Either String (Tuple Json Int)
  pNumber i =
    let j = numEnd i in
    if j == i then err "expected a value" i
    else case Number.fromString (CU.slice i j input) of
      Just n -> Right (Tuple (JNum n) j)
      Nothing -> err "malformed number" i
    where
    numEnd :: Int -> Int
    numEnd k = case peek k of
      Just c | isNumChar c -> numEnd (k + 1)
      _ -> k

  -- Accumulates reversed segments; rejoined once at the closing quote.
  pString :: Int -> List String -> Either String (Tuple String Int)
  pString i acc = case peek i of
    Nothing -> err "unterminated string" i
    Just '"' -> Right (Tuple (joinWith "" (Array.reverse (List.toUnfoldable acc))) (i + 1))
    Just '\\' -> case peek (i + 1) of
      Just c -> do
        seg <- unescape c (i + 1)
        pString (i + 2) (seg : acc)
      Nothing -> err "unterminated escape" i
    Just c -> pString (i + 1) (CU.singleton c : acc)

  unescape :: Char -> Int -> Either String String
  unescape c i = case c of
    '\\' -> Right "\\"
    '"' -> Right "\""
    '/' -> Right "/"
    'n' -> Right "\n"
    't' -> Right "\t"
    'r' -> Right "\r"
    'b' -> Right "\x08"
    'f' -> Right "\x0C"
    _ -> err "unsupported escape (canonical subset has no \\u)" i

  pArray :: Int -> List Json -> Either String (Tuple Json Int)
  pArray i acc = case peek i of
    Just ']' | List.null acc -> Right (Tuple (JArr []) (i + 1))
    _ -> do
      Tuple v j <- pValue i
      let k = skipWs j
      case peek k of
        Just ',' -> pArray (skipWs (k + 1)) (v : acc)
        Just ']' -> Right (Tuple (JArr (Array.reverse (List.toUnfoldable (v : acc)))) (k + 1))
        _ -> err "expected , or ] in array" k

  pObject :: Int -> List (Tuple String Json) -> Either String (Tuple Json Int)
  pObject i acc = case peek i of
    Just '}' | List.null acc -> Right (Tuple (JObj []) (i + 1))
    Just '"' -> do
      Tuple k j <- pString (i + 1) Nil
      let j' = skipWs j
      case peek j' of
        Just ':' -> do
          Tuple v m <- pValue (skipWs (j' + 1))
          let m' = skipWs m
          case peek m' of
            Just ',' -> pObject (skipWs (m' + 1)) (Tuple k v : acc)
            Just '}' -> Right (Tuple (JObj (Array.reverse (List.toUnfoldable (Tuple k v : acc)))) (m' + 1))
            _ -> err "expected , or } in object" m'
        _ -> err "expected : after object key" j'
    _ -> err "expected object key" i
