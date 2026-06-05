{-# LANGUAGE OverloadedStrings #-}

-- |
-- Naming and identifier utilities for the Julia backend.
--
-- PureScript module names keep their case and join segments with
-- underscores (@Data.Array@ -> @Data_Array@). Identifiers keep their
-- camelCase; primes become the unicode prime character (a legal Julia
-- identifier char, idiomatic for derivatives), and Julia reserved words
-- get an underscore suffix.
--
module Language.PureScript.Julia.CodeGen.Common
  ( jlModuleName
  , jlFileName
  , jlForeignFileName
  , toJuliaIdent
  , identToJlName
  , runIdent'
  , psStringToText
  , escapeStringJl
  , escapeCharJl
  , nameIsJuliaReserved
  ) where

import Prelude
import Data.Char (isAlpha, isDigit)
import Data.Text (Text, uncons, singleton, pack)
import qualified Data.Text as T
import Data.Word (Word16)
import Language.PureScript.Names
    ( ModuleName(..), Ident (InternalIdent), runIdent, InternalIdentData (RuntimeLazyFactory, Lazy) )
import Language.PureScript.PSString (PSString, decodeStringEither)
import Numeric (showHex)

-- | Convert a ModuleName to a Julia module name
-- e.g., Data.Array -> Data_Array; Main -> Main_ (to avoid Julia's Main)
jlModuleName :: ModuleName -> Text
jlModuleName (ModuleName name) =
  let base = T.intercalate "_" (T.splitOn "." name)
  in if base `elem` ["Main", "Base", "Core", "PurejlRuntime"]
     then base <> "_"
     else base

-- | Output filename for a PureScript module
jlFileName :: ModuleName -> FilePath
jlFileName mn = T.unpack (jlModuleName mn) <> ".jl"

-- | Filename of the foreign (FFI) companion file for a module
jlForeignFileName :: ModuleName -> FilePath
jlForeignFileName mn = T.unpack (jlModuleName mn) <> "_foreign.jl"

-- | Convert a PSString to escaped Julia string content
psStringToText :: PSString -> Text
psStringToText a = foldMap escapeChar (decodeStringEither a)
  where
    escapeChar :: Either Word16 Char -> Text
    escapeChar (Left w) = "\\u" <> hex 4 w
    escapeChar (Right c) = replaceBasicEscape c

replaceBasicEscape :: Char -> Text
replaceBasicEscape '\b' = "\\b"
replaceBasicEscape '\t' = "\\t"
replaceBasicEscape '\n' = "\\n"
replaceBasicEscape '\f' = "\\f"
replaceBasicEscape '\r' = "\\r"
replaceBasicEscape '"'  = "\\\""
replaceBasicEscape '\\' = "\\\\"
replaceBasicEscape '$'  = "\\$"   -- Julia string interpolation!
replaceBasicEscape c = singleton c

-- | Escape plain Text for embedding in a Julia string literal
escapeStringJl :: Text -> Text
escapeStringJl = T.concatMap replaceBasicEscape

-- | Escape a character for a Julia character literal
escapeCharJl :: Char -> Text
escapeCharJl '\'' = "\\'"
escapeCharJl '\\' = "\\\\"
escapeCharJl '\n' = "\\n"
escapeCharJl '\r' = "\\r"
escapeCharJl '\t' = "\\t"
escapeCharJl c = singleton c

hex :: (Enum a) => Int -> a -> Text
hex width c =
  let hs = showHex (fromEnum c) "" in
  pack (replicate (width - length hs) '0' <> hs)

-- | Convert a PureScript identifier to a valid Julia identifier
toJuliaIdent :: Text -> Text
toJuliaIdent v = case uncons v of
  Just (h, t) ->
    replaceFirst h <> T.concatMap replaceChar t
  Nothing -> v
  where
    replaceChar '.' = "_"
    replaceChar '$' = "_dollar_"
    replaceChar '\'' = "\x2032"   -- prime
    replaceChar '-' = "_"
    replaceChar c | isValidJuliaChar c = singleton c
    replaceChar c = "_u" <> hex 4 c

    replaceFirst x
      | isAlpha x || x == '_' = singleton x
      | otherwise = "_" <> replaceChar x

    isValidJuliaChar c = isAlpha c || isDigit c || c == '_' || c == '\x2032'

-- | Convert an Ident to a Julia name, escaping reserved words
identToJlName :: Ident -> Text
identToJlName ident =
  let name = toJuliaIdent (runIdent' ident)
  in if nameIsJuliaReserved name
     then name <> "_"
     else name

-- | Get the raw text from an Ident, handling internal identifiers
runIdent' :: Ident -> Text
runIdent' = \case
  InternalIdent RuntimeLazyFactory -> "_runtime_lazy"
  InternalIdent (Lazy name) -> "_lazy_" <> name
  other -> runIdent other

-- |
-- Checks whether an identifier name is reserved in Julia.
--
nameIsJuliaReserved :: Text -> Bool
nameIsJuliaReserved name = name `elem` juliaReserved

-- | Julia reserved words (keywords, contextual keywords, and per-module
-- auto-bindings that cannot be assigned)
juliaReserved :: [Text]
juliaReserved =
  [ "begin", "while", "if", "for", "try", "return"
  , "break", "continue", "function", "macro", "quote"
  , "let", "local", "global", "const", "do"
  , "struct", "module", "baremodule"
  , "using", "import", "export", "public"
  , "end", "else", "elseif", "catch", "finally"
  , "true", "false"
  -- contextual keywords
  , "abstract", "mutable", "primitive", "type"
  , "where", "in", "isa", "outer", "as"
  -- per-module auto-bindings and unassignable names
  , "nothing", "missing", "include", "eval"
  , "Main", "Base", "Core"
  ]
