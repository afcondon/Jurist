module Test.Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)

-- | backend-jl's real test is the differential corpus (`./run_conformance.sh`),
-- | which diffs generated Julia against the JS reference byte-for-byte. This
-- | placeholder exists only so `spago test` has an entry point.
main :: Effect Unit
main = log "backend-jl: see ./run_conformance.sh for the conformance suite"
