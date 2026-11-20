-- | The compute leaf: PureScript says what to integrate, Julia runs it as
-- | native code, and PureScript inspects and serialises what comes back.
-- |
-- | The Lorenz system is written below as a `Data.Simulation.Spec`: three
-- | rates of change over named variables. `Data.Simulation` builds the
-- | Runge-Kutta step from them, and `Data.Simulation.Julia` has Julia
-- | compile it into one loop. This example has no foreign file. Until
-- | November 2026 it had one, holding an RK4 loop written by hand in Julia;
-- | the numbers printed here are the same ones that loop printed.
module Main where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromNumber, fromObject, stringify)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Data.NumExpr (num, var)
import Data.Simulation (Frame, Spec, simulation)
import Data.Simulation.Julia as Julia
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Foreign.Object as Object

type Point = { x :: Number, y :: Number, z :: Number }

lorenz :: Spec
lorenz =
  { inputs: [ "sigma", "rho", "dt", "until" ]
  , derived: []
  , state:
      [ { name: "x", initial: one, rate: var "sigma" * (y - x) }
      , { name: "y", initial: one, rate: x * (var "rho" - z) - y }
      , { name: "z", initial: one, rate: x * y - num (8.0 / 3.0) * z }
      ]
  , held: []
  , updates: []
  , timeStep: var "dt"
  , horizon: var "until"
  , events: []
  }
  where
  x = var "x"
  y = var "y"
  z = var "z"

-- | The orbit from (1, 1, 1): the point after each step, the start left out.
lorenzOrbit :: Julia.Compiled -> Number -> Int -> Effect (Array Point)
lorenzOrbit compiled dt steps = do
  -- The run stops at the first step that reaches the horizon, so a horizon
  -- half a step short of `steps` steps is passed by exactly that many.
  frames <- Julia.trajectory compiled 1 [ 10.0, 28.0, dt, dt * (toNumber steps - 0.5) ]
  pure (Array.mapMaybe point (Array.drop 1 frames))

point :: Frame -> Maybe Point
point frame = case frame.state of
  [ x, y, z ] -> Just { x, y, z }
  _ -> Nothing

pointJson :: Point -> Json
pointJson p = fromObject
  (Object.fromFoldable [ Tuple "x" (fromNumber p.x), Tuple "y" (fromNumber p.y), Tuple "z" (fromNumber p.z) ])

main :: Effect Unit
main = case simulation lorenz of
  Left problem -> log ("not a simulation: " <> problem)
  Right sim -> do
    compiled <- Julia.compile sim
    orbit <- lorenzOrbit compiled 0.01 5000
    -- PureScript inspecting data Julia computed.
    log ("points: " <> show (Array.length orbit))
    let maxZ = foldl (\m p -> max m p.z) 0.0 orbit
    log ("maxZ: " <> show maxZ)
    -- JSON at the seam, as a browser would be sent it.
    log (stringify (fromArray (map pointJson (Array.take 2 orbit))))
