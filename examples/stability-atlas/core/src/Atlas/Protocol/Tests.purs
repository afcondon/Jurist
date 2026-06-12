-- | Differential parity tests for the wire contract, in the test-suite
-- | style: every line is `TEST <name>: <value>`, and the SAME module runs
-- | on Node (reference semantics) and Julia (purejl); outputs must be
-- | byte-identical. Exercised numbers deliberately include the actual
-- | protocol values (μ = 9.54e-4) and awkward forms (exponents, negatives).
module Atlas.Protocol.Tests (runTests) where

import Prelude

import Atlas.Dynamics (initialState, integrateSteps, jacobi)
import Atlas.Json (Json(..), parseJson, printJson)
import Atlas.Protocol
  ( ClientMsg(..)
  , ServerMsg(..)
  , decodeClientMsg
  , decodeServerMsg
  , encodeClientMsg
  , encodeServerMsg
  )
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name value = log ("TEST " <> name <> ": " <> value)

showEither :: Either String String -> String
showEither = case _ of
  Left e -> "Left: " <> e
  Right s -> "Right: " <> s

reqSweep :: ClientMsg
reqSweep = RequestSweep
  { aMin: 0.3
  , aMax: 0.85
  , eMin: 0.0
  , eMax: 0.35
  , cols: 320
  , rows: 200
  , horizonPeriods: 500.0
  , mu: 9.54e-4
  , withFli: true
  }

reqTraj :: ClientMsg
reqTraj = RequestTrajectory
  { a: 0.4806, e: 0.12, horizonPeriods: 50.0, mu: 9.54e-4, frameStride: 4 }

sweepRows :: ServerMsg
sweepRows = SweepRows
  { rowStart: 17
  , rows: [ [ 500.0, 123.25, -0.5 ], [ 1.0e-9, 42.0, 0.125 ] ]
  }

trajFrames :: ServerMsg
trajFrames = TrajFrames
  { frames:
      [ { t: 0.0, x: 0.4806, y: 0.0, vx: 0.0, vy: 1.602, jacobi: 3.0124 }
      , { t: 0.25, x: 0.4791, y: 0.1183, vx: -0.191, vy: 1.588, jacobi: 3.0124 }
      ]
  }

-- | decode then re-encode: proves the codec closes over its own output.
roundtripClient :: ClientMsg -> String
roundtripClient msg = showEither (map encodeClientMsg (decodeClientMsg (encodeClientMsg msg)))

roundtripServer :: ServerMsg -> String
roundtripServer msg = showEither (map encodeServerMsg (decodeServerMsg (encodeServerMsg msg)))

runTests :: Effect Unit
runTests = do
  -- Atlas.Json primitives
  t "json-null" (printJson JNull)
  t "json-num-int-valued" (printJson (JNum 500.0))
  t "json-num-frac" (printJson (JNum 123.25))
  t "json-num-neg" (printJson (JNum (-0.5)))
  t "json-num-small" (printJson (JNum 1.0e-9))
  t "json-num-mu" (printJson (JNum 9.54e-4))
  t "json-str-escapes" (printJson (JStr "line\nquote\"back\\slash\ttab"))
  t "json-nested"
    ( printJson
        ( JObj
            [ Tuple "xs" (JArr [ JNum 1.0, JBool false, JNull ])
            , Tuple "o" (JObj [ Tuple "k" (JStr "v") ])
            ]
        )
    )
  -- parser: canonical output language, whitespace, errors
  t "parse-roundtrip-nested" (showEither (map printJson (parseJson "{\"xs\":[1.0,false,null],\"o\":{\"k\":\"v\"}}")))
  t "parse-whitespace" (showEither (map printJson (parseJson "  { \"a\" : [ 1.5 , true ] }  ")))
  t "parse-escapes" (showEither (map printJson (parseJson "\"a\\nb\\\"c\\\\d\"")))
  t "parse-err-trailing" (showEither (map printJson (parseJson "null x")))
  t "parse-err-unterminated" (showEither (map printJson (parseJson "{\"a\":1")))
  t "parse-err-bad-escape" (showEither (map printJson (parseJson "\"\\u0041\"")))
  -- protocol golden encodings
  t "enc-RequestSweep" (encodeClientMsg reqSweep)
  t "enc-RequestTrajectory" (encodeClientMsg reqTraj)
  t "enc-CancelSweep" (encodeClientMsg CancelSweep)
  t "enc-SweepRows" (encodeServerMsg sweepRows)
  t "enc-SweepDone" (encodeServerMsg (SweepDone { elapsedMs: 4211.5 }))
  t "enc-TrajFrames" (encodeServerMsg trajFrames)
  t "enc-TrajDone" (encodeServerMsg TrajDone)
  t "enc-ProtocolError" (encodeServerMsg (ProtocolError "unknown tag \"Zap\""))
  -- decode∘encode closure
  t "rt-RequestSweep" (roundtripClient reqSweep)
  t "rt-RequestTrajectory" (roundtripClient reqTraj)
  t "rt-CancelSweep" (roundtripClient CancelSweep)
  t "rt-SweepRows" (roundtripServer sweepRows)
  t "rt-TrajFrames" (roundtripServer trajFrames)
  t "rt-ProtocolError" (roundtripServer (ProtocolError "boom"))
  -- decode hostile input
  t "dec-unknown-tag" (showEither (map encodeClientMsg (decodeClientMsg "{\"tag\":\"Zap\"}")))
  t "dec-missing-field" (showEither (map encodeClientMsg (decodeClientMsg "{\"tag\":\"RequestTrajectory\",\"a\":0.5}")))
  t "dec-not-json" (showEither (map encodeClientMsg (decodeClientMsg "hello")))
  t "dec-non-integer" (showEither (map encodeClientMsg (decodeClientMsg "{\"tag\":\"RequestTrajectory\",\"a\":0.5,\"e\":0.1,\"horizonPeriods\":50.0,\"mu\":9.54e-4,\"frameStride\":4.5}")))
  -- dynamics: the pure CR3BP denotation must be bit-identical across
  -- backends (same IEEE doubles through sqrt/pow and full-precision show)
  let mu = 9.54e-4
  let s0 = initialState mu 0.4806 0.12
  let s1k = integrateSteps mu 1.0e-3 1000 s0
  t "dyn-initial-state" (showState s0)
  t "dyn-rk4-1000-steps" (showState s1k)
  t "dyn-jacobi-0" (show (jacobi mu s0))
  t "dyn-jacobi-drift-1000" (show (jacobi mu s1k - jacobi mu s0))
  where
  showState :: { x :: Number, y :: Number, vx :: Number, vy :: Number } -> String
  showState s = show s.x <> " " <> show s.y <> " " <> show s.vx <> " " <> show s.vy
