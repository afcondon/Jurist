-- | The same systems, the same inputs, on Node: only the interpreter, since
-- | Node has no Julia to compile for. It prints the lines `Systems.report`
-- | gives for the first run of each system, and `bin/demos.py` requires
-- | each of them to appear, character for character, in the output of the
-- | Julia program. That is the claim a browser needs: an orbit computed in
-- | Julia can be recomputed in JavaScript and come out the same.
module Main where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Simulation (simulate, simulation)
import Data.Traversable (for_, traverse_)
import Effect (Effect)
import Effect.Console (log)
import Systems (cases, report)

main :: Effect Unit
main = for_ cases \{ spec, rows } ->
  case simulation spec of
    Left problem -> log ("  not a simulation: " <> problem)
    Right sim -> for_ (Array.head rows) \inputs ->
      traverse_ log (report (simulate sim inputs))
