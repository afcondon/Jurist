-- | One integrator, written in PureScript, run two ways and compared.
-- |
-- | Each system in `Systems` is a `Data.Simulation.Spec`. `Data.Simulation`
-- | turns it into a program for one Runge-Kutta step. That program is
-- | interpreted here by `Data.Simulation.simulate`, which is plain
-- | PureScript and runs on any backend, and compiled by Julia through
-- | `Data.Simulation.Julia`. Every comparison printed below is exact
-- | equality of doubles.
module Main where

import Prelude

import Atlas.Survival as Atlas
import Data.Array (all, filter, length, zipWith)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.NumExpr.Program (instructions)
import Data.Simulation (simulate, simulation, stepProgram, trajectory)
import Data.Simulation.Julia as Julia
import Data.Traversable (for_, traverse_)
import Effect (Effect)
import Effect.Console (log)
import Systems (Case, cases, report)

foreign import writeText :: String -> String -> Effect Unit

main :: Effect Unit
main = do
  traverse_ check cases
  case simulation Atlas.survival of
    Left problem -> log ("three-body kernel: " <> problem)
    Right sim -> do
      compiled <- Julia.compile sim
      writeText "cr3bp-survival.jl" (Julia.source compiled <> "\n")
      log "wrote cr3bp-survival.jl, the function Julia compiled for the three-body run"

-- Run every row of inputs through both denotations and say whether they
-- agree, exactly, on how each run ended and on every frame of the first.
check :: Case -> Effect Unit
check { title, spec, rows } = do
  log ("== " <> title <> " ==")
  case simulation spec of
    Left problem -> log ("  not a simulation: " <> problem)
    Right sim -> do
      compiled <- Julia.compile sim
      log ("  one step is " <> show (length (instructions (stepProgram sim))) <> " instructions")
      swept <- Julia.sweep compiled rows
      let
        interpreted = map (simulate sim) rows
        eventIndex outcome = case outcome.event of
          Just i -> i
          Nothing -> -1
      log ("  runs: " <> show (length rows)
        <> ", ended by an event: " <> show (length (filter (_ >= 0) swept.events)))
      log ("  end times identical:  " <> show (map _.time interpreted == swept.times))
      log ("  events identical:     " <> show (map eventIndex interpreted == swept.events))
      log ("  step counts identical: " <> show (map _.steps interpreted == swept.steps))
      for_ (Array.head rows) \inputs -> do
        compiledRun <- Julia.simulate compiled inputs
        let reference = simulate sim inputs
        traverse_ log (report reference)
        log ("  final state identical: " <> show (reference.state == compiledRun.state))
        frames <- Julia.trajectory compiled 7 inputs
        let interpretedFrames = trajectory sim 7 inputs
        log ("  frames at stride 7: " <> show (length interpretedFrames)
          <> ", identical: " <> show (sameFrames interpretedFrames frames))
  where
  sameFrames xs ys =
    length xs == length ys
      && all identity (zipWith (\p q -> p.time == q.time && p.state == q.state) xs ys)
