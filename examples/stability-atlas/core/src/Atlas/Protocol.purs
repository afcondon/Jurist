-- | The typed wire contract of the stability atlas — ONE module compiled to
-- | both ends of the WebSocket (JS in the browser, Julia in the service).
-- | The ADTs are the protocol; the codecs below are its only serialization.
-- | A field added here without updating a decoder is a compile error on
-- | both ends simultaneously — that is the demo's thesis.
module Atlas.Protocol
  ( SweepSpec
  , TrajSpec
  , Frame
  , ClientMsg(..)
  , ServerMsg(..)
  , encodeClientMsg
  , decodeClientMsg
  , encodeServerMsg
  , decodeServerMsg
  ) where

import Prelude

import Atlas.Json (Json(..), parseJson, printJson)
import Data.Either (Either(..))
import Data.Foldable (find)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)

-- | A sweep experiment: a grid over (semi-major axis × eccentricity) of
-- | test-asteroid initial conditions in the Sun–Jupiter CR3BP. Zone B:
-- | answered by progressive SweepRows blocks, closed by SweepDone.
-- |
-- | Verdict encoding in SweepRows: v ∈ [0,1) — the orbit was LOST at
-- | survival fraction v of the horizon; v ∈ [1,2] — survived, and when
-- | withFli is set, (v−1)·8 is the Fast Lyapunov Indicator (log₁₀ of
-- | tangent-vector growth, capped at 8) — the chaos layer that resolves
-- | the resonance web among survivors.
type SweepSpec =
  { aMin :: Number
  , aMax :: Number
  , eMin :: Number
  , eMax :: Number
  , cols :: Int
  , rows :: Int
  , horizonPeriods :: Number
  , mu :: Number
  , withFli :: Boolean
  }

-- | A single-orbit request for the orrery. Zone A: answered by a stream of
-- | TrajFrames blocks, closed by TrajDone.
type TrajSpec =
  { a :: Number
  , e :: Number
  , horizonPeriods :: Number
  , mu :: Number
  , frameStride :: Int
  }

-- | One trajectory sample in the rotating frame. The Jacobi constant rides
-- | along so the frontend can plot integrator honesty live.
type Frame =
  { t :: Number
  , x :: Number
  , y :: Number
  , vx :: Number
  , vy :: Number
  , jacobi :: Number
  }

data ClientMsg
  = RequestSweep SweepSpec
  | RequestTrajectory TrajSpec
  | CancelSweep

data ServerMsg
  = SweepRows { rowStart :: Int, rows :: Array (Array Number) }
  | SweepDone { elapsedMs :: Number }
  | TrajFrames { frames :: Array Frame }
  | TrajDone
  | ProtocolError String

-- Encoding ------------------------------------------------------------------

tagged :: String -> Array (Tuple String Json) -> Json
tagged tag fields = JObj ([ Tuple "tag" (JStr tag) ] <> fields)

num :: Number -> Json
num = JNum

int :: Int -> Json
int = JNum <<< Int.toNumber

encodeClientMsg :: ClientMsg -> String
encodeClientMsg = printJson <<< case _ of
  RequestSweep s -> tagged "RequestSweep"
    [ Tuple "aMin" (num s.aMin)
    , Tuple "aMax" (num s.aMax)
    , Tuple "eMin" (num s.eMin)
    , Tuple "eMax" (num s.eMax)
    , Tuple "cols" (int s.cols)
    , Tuple "rows" (int s.rows)
    , Tuple "horizonPeriods" (num s.horizonPeriods)
    , Tuple "mu" (num s.mu)
    , Tuple "withFli" (JBool s.withFli)
    ]
  RequestTrajectory t -> tagged "RequestTrajectory"
    [ Tuple "a" (num t.a)
    , Tuple "e" (num t.e)
    , Tuple "horizonPeriods" (num t.horizonPeriods)
    , Tuple "mu" (num t.mu)
    , Tuple "frameStride" (int t.frameStride)
    ]
  CancelSweep -> tagged "CancelSweep" []

encodeServerMsg :: ServerMsg -> String
encodeServerMsg = printJson <<< case _ of
  SweepRows r -> tagged "SweepRows"
    [ Tuple "rowStart" (int r.rowStart)
    , Tuple "rows" (JArr (map (JArr <<< map num) r.rows))
    ]
  SweepDone d -> tagged "SweepDone" [ Tuple "elapsedMs" (num d.elapsedMs) ]
  TrajFrames f -> tagged "TrajFrames" [ Tuple "frames" (JArr (map frameJson f.frames)) ]
  TrajDone -> tagged "TrajDone" []
  ProtocolError e -> tagged "ProtocolError" [ Tuple "message" (JStr e) ]
  where
  frameJson :: Frame -> Json
  frameJson f = JObj
    [ Tuple "t" (num f.t)
    , Tuple "x" (num f.x)
    , Tuple "y" (num f.y)
    , Tuple "vx" (num f.vx)
    , Tuple "vy" (num f.vy)
    , Tuple "jacobi" (num f.jacobi)
    ]

-- Decoding ------------------------------------------------------------------

field :: String -> Array (Tuple String Json) -> Either String Json
field k kvs = case find (\kv -> fst kv == k) kvs of
  Just kv -> Right (snd kv)
  Nothing -> Left ("missing field: " <> k)

asNumber :: Json -> Either String Number
asNumber = case _ of
  JNum n -> Right n
  _ -> Left "expected a number"

asInt :: Json -> Either String Int
asInt j = do
  n <- asNumber j
  case Int.fromNumber n of
    Just i -> Right i
    Nothing -> Left "expected an integer"

asString :: Json -> Either String String
asString = case _ of
  JStr s -> Right s
  _ -> Left "expected a string"

asBoolean :: Json -> Either String Boolean
asBoolean = case _ of
  JBool b -> Right b
  _ -> Left "expected a boolean"

asArray :: Json -> Either String (Array Json)
asArray = case _ of
  JArr xs -> Right xs
  _ -> Left "expected an array"

asObject :: Json -> Either String (Array (Tuple String Json))
asObject = case _ of
  JObj kvs -> Right kvs
  _ -> Left "expected an object"

numField :: String -> Array (Tuple String Json) -> Either String Number
numField k kvs = field k kvs >>= asNumber

intField :: String -> Array (Tuple String Json) -> Either String Int
intField k kvs = field k kvs >>= asInt

withTagged :: forall a. String -> (String -> Array (Tuple String Json) -> Either String a) -> Either String a
withTagged raw k = do
  j <- parseJson raw
  kvs <- asObject j
  tag <- field "tag" kvs >>= asString
  k tag kvs

decodeClientMsg :: String -> Either String ClientMsg
decodeClientMsg raw = withTagged raw \tag kvs -> case tag of
  "RequestSweep" -> ado
    aMin <- numField "aMin" kvs
    aMax <- numField "aMax" kvs
    eMin <- numField "eMin" kvs
    eMax <- numField "eMax" kvs
    cols <- intField "cols" kvs
    rows <- intField "rows" kvs
    horizonPeriods <- numField "horizonPeriods" kvs
    mu <- numField "mu" kvs
    withFli <- field "withFli" kvs >>= asBoolean
    in RequestSweep { aMin, aMax, eMin, eMax, cols, rows, horizonPeriods, mu, withFli }
  "RequestTrajectory" -> ado
    a <- numField "a" kvs
    e <- numField "e" kvs
    horizonPeriods <- numField "horizonPeriods" kvs
    mu <- numField "mu" kvs
    frameStride <- intField "frameStride" kvs
    in RequestTrajectory { a, e, horizonPeriods, mu, frameStride }
  "CancelSweep" -> Right CancelSweep
  _ -> Left ("unknown ClientMsg tag: " <> tag)

decodeServerMsg :: String -> Either String ServerMsg
decodeServerMsg raw = withTagged raw \tag kvs -> case tag of
  "SweepRows" -> ado
    rowStart <- intField "rowStart" kvs
    rows <- field "rows" kvs >>= asArray >>= traverse (asArray >=> traverse asNumber)
    in SweepRows { rowStart, rows }
  "SweepDone" -> ado
    elapsedMs <- numField "elapsedMs" kvs
    in SweepDone { elapsedMs }
  "TrajFrames" -> ado
    frames <- field "frames" kvs >>= asArray >>= traverse decodeFrame
    in TrajFrames { frames }
  "TrajDone" -> Right TrajDone
  "ProtocolError" -> ado
    message <- field "message" kvs >>= asString
    in ProtocolError message
  _ -> Left ("unknown ServerMsg tag: " <> tag)
  where
  decodeFrame :: Json -> Either String Frame
  decodeFrame j = do
    kvs <- asObject j
    ado
      t <- numField "t" kvs
      x <- numField "x" kvs
      y <- numField "y" kvs
      vx <- numField "vx" kvs
      vy <- numField "vy" kvs
      jacobi <- numField "jacobi" kvs
      in { t, x, y, vx, vy, jacobi }
