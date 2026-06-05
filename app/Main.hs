{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude
import System.Environment (getArgs)
import Language.PureScript.Julia.Make (compile, CompileOptions(..))

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--help"] -> printHelp
    ["-h"] -> printHelp
    ["--version"] -> printVersion
    ["-v"] -> printVersion
    [] ->
      compile CompileOptions
        { inputDir = "output"
        , outputDir = "output-jl"
        }
    [input] ->
      compile CompileOptions
        { inputDir = input
        , outputDir = "output-jl"
        }
    [input, output] ->
      compile CompileOptions
        { inputDir = input
        , outputDir = output
        }
    _ -> do
      putStrLn "Usage: purejl [INPUT_DIR] [OUTPUT_DIR]"
      putStrLn "Run 'purejl --help' for more information."

printHelp :: IO ()
printHelp = do
  putStrLn "purejl - PureScript to Julia compiler"
  putStrLn ""
  putStrLn "Usage: purejl [INPUT_DIR] [OUTPUT_DIR]"
  putStrLn ""
  putStrLn "Arguments:"
  putStrLn "  INPUT_DIR   Directory containing corefn.json files (default: output)"
  putStrLn "  OUTPUT_DIR  Directory for Julia output (default: output-jl)"
  putStrLn ""
  putStrLn "Options:"
  putStrLn "  -h, --help     Show this help message"
  putStrLn "  -v, --version  Show version information"
  putStrLn ""
  putStrLn "Example workflow:"
  putStrLn "  1. spago build      # Generate CoreFn in output/ (needs a backend configured)"
  putStrLn "  2. purejl           # Generate Julia in output-jl/"
  putStrLn "  3. julia output-jl/main.jl"

printVersion :: IO ()
printVersion = do
  putStrLn "purejl 0.0.1"
  putStrLn "PureScript to Julia compiler"
  putStrLn ""
  putStrLn "Supports PureScript 0.15.x"
