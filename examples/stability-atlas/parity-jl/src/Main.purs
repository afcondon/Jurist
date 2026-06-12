module Main where

import Prelude

import Atlas.Protocol.Tests (runTests)
import Effect (Effect)

main :: Effect Unit
main = runTests
