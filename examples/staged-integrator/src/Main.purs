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
  write "cr3bp-survival.jl" "the three-body run" Atlas.survival
  write "cr3bp-chaos.jl" "the three-body run with its chaos indicator" Atlas.chaos
  where
  write file what spec = case simulation spec of
    Left problem -> log (what <> ": " <> problem)
    Right sim -> do
      compiled <- Julia.compile sim
      writeText file (Julia.source compiled <> "\n")
      log ("wrote " <> file <> ", the function Julia compiled for " <> what)

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
      log ("  final states identical: " <> show (map _.state interpreted == swept.states))
      for_ (Array.head rows) \inputs -> do
        compiledRun <- Julia.simulate compiled inputs
        let reference = simulate sim inputs
        traverse_ log (report reference)
        log ("  the same run alone, identical: " <> show (reference.state == compiledRun.state && reference.time == compiledRun.time))
        frames <- Julia.trajectory compiled 7 inputs
        let interpretedFrames = trajectory sim 7 inputs
        log ("  frames at stride 7: " <> show (length interpretedFrames)
          <> ", identical: " <> show (sameFrames interpretedFrames frames))
  where
  sameFrames xs ys =
    length xs == length ys
      && all identity (zipWith (\p q -> p.time == q.time && p.state == q.state) xs ys)
