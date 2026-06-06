-- | The "thin skin" demo: PureScript defines the contract and does the
-- | cold glue; Julia does the hot numerics; JSON crosses the boundary.
-- |
-- | This is the seam the whole backend exists for — a Julia compute leaf
-- | (here: Lorenz attractor via RK4, in the FFI shim) feeding typed data
-- | to PureScript, which inspects it and serializes it for a consumer
-- | (eventually: a Hylograph visualization over a WebSocket).
module Main where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.Function.Uncurried (Fn4, runFn4)
import Effect (Effect)
import Effect.Console (log)

type Point = { x :: Number, y :: Number, z :: Number }

-- | RK4 integration of the Lorenz system, implemented in Julia.
-- | Args: sigma/rho/beta-style start point is fixed; (dt, steps).
foreign import lorenzOrbitImpl :: Fn4 Number Number Number Int (Array Point)

-- | JSON serialization of any PS runtime value, implemented in Julia
-- | (Dicts, Vectors, numbers, strings, booleans, nothing).
foreign import toJson :: forall a. a -> String

lorenzOrbit :: Number -> Int -> Array Point
lorenzOrbit dt steps = runFn4 lorenzOrbitImpl 10.0 28.0 dt steps

main :: Effect Unit
main = do
  let orbit = lorenzOrbit 0.01 5000
  -- PS-side inspection of Julia-computed data (the boundary is zero-copy)
  log ("points: " <> show (Array.length orbit))
  let maxZ = foldl (\m p -> max m p.z) 0.0 orbit
  log ("maxZ: " <> show maxZ)
  -- JSON at the seam — stand-in for the WebSocket push to Hylograph
  log (toJson (Array.take 2 orbit))
