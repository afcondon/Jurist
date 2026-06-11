-- | Emit the `integratePure` Lorenz orbit as a JS global for the jurist-demos
-- | site (`site/lorenz.html`): x/z pairs, the classic butterfly projection.
-- | Run with stdout redirected:
-- |   node -e "import('./output/DumpOrbit/index.js').then(m => m.main())" > ../../../site/data/lorenz.js
-- | The data is computed by the same pure-PS RK4 the receipts show running
-- | bit-identically on Node, the BEAM, and Julia — the site plots a trajectory
-- | every runtime agrees on, byte for byte.
module DumpOrbit where

import Prelude

import Data.Array (length) as Array
import Data.Array ((!!)) as Array
import Data.Maybe (fromMaybe)
import Data.Number.Format (fixed, toStringWith)
import Data.String (joinWith)
import Data.SystemSpec (integratePure)
import Effect (Effect)
import Effect.Console (log)
import Main (lorenz)

-- 3 decimals is ample for a 720px plot; keeps the committed data small.
fmt :: Number -> String
fmt n = toStringWith (fixed 3) n

pair :: Array Number -> String
pair st = "[" <> fmt (get 0) <> "," <> fmt (get 2) <> "]"
  where
  get i = fromMaybe 0.0 (st Array.!! i)

main :: Effect Unit
main = do
  let
    orbit = integratePure lorenz
      { x: 1.0, y: 1.0, z: 1.0 }
      { sigma: 10.0, rho: 28.0, beta: 8.0 / 3.0 }
      0.01
      5000
    body = joinWith "," (map pair orbit)
  log ("window.LORENZ = {\"steps\":" <> show (Array.length orbit)
    <> ",\"xz\":[" <> body <> "]};")
