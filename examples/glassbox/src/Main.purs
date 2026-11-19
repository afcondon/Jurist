-- | Glassbox on Julia: regenerate the conformance vectors for every machine
-- | in a directory. The lane (bin/demos.py) compares them with the committed
-- | ones. All the logic is Glassbox's own; this module only reads and writes.
module Main where

import Prelude

import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log)
import Glassbox.Codec.JSON (parseSpec)
import Glassbox.Conformance (printSuite, suiteFor)

foreign import machineNames :: String -> Effect (Array String)
foreign import readText :: String -> Effect String
foreign import writeText :: String -> String -> Effect Unit
foreign import arg :: Int -> Effect String

main :: Effect Unit
main = do
  inDir <- arg 0
  outDir <- arg 1
  names <- machineNames inDir
  for_ names \name -> do
    text <- readText (inDir <> "/" <> name <> ".json")
    case parseSpec text of
      Left err -> log (name <> ": DECODE FAILED: " <> err)
      Right spec -> do
        writeText (outDir <> "/" <> name <> ".json") (printSuite (suiteFor spec))
        log (name <> ".json written")
