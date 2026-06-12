-- | The stability atlas, browser side. One Halogen component: a canvas
-- | heat map over (semi-major axis × eccentricity) of test asteroids in
-- | the Sun–Jupiter CR3BP, painted progressively as SweepRows blocks
-- | stream from the PS-on-Julia service. Preview sweep first (coarse,
-- | seconds), full sweep refines behind it.
-- |
-- | All wire traffic goes through Atlas.Protocol — the same module the
-- | service compiles to Julia.
module Atlas.App (component) where

import Prelude

import Atlas.Protocol (ClientMsg(..), Frame, ServerMsg(..), SweepSpec, decodeServerMsg, encodeClientMsg)
import Control.Monad.Except (runExcept)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.FoldableWithIndex (forWithIndex_)
import Data.Int (floor, toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number (abs, cos, pow, sin)
import Data.Number.Format (exponential, fixed, toStringWith)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Console (warn)
import Effect.Timer as Timer
import Foreign (readString)
import Graphics.Canvas as GC
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Web.DOM.Element (getBoundingClientRect)
import Web.Event.Event (Event)
import Web.Event.EventTarget (addEventListener, eventListener)
import Web.HTML.HTMLElement as HTMLElement
import Web.Socket.Event.EventTypes (onClose, onMessage, onOpen) as WSE
import Web.Socket.Event.MessageEvent as MessageEvent
import Web.Socket.WebSocket as WS
import Web.UIEvent.MouseEvent (MouseEvent)
import Web.UIEvent.MouseEvent as MouseEvent

-- Geometry: canvas is W×H CSS pixels; the sweep grid maps onto it with
-- square-ish cells, e increasing upward.
canvasW :: Number
canvasW = 720.0

canvasH :: Number
canvasH = 450.0

serviceUrl :: String
serviceUrl = "ws://localhost:3210"

-- The two-pass experiment: coarse preview, then full resolution.
previewSpec :: Number -> Boolean -> SweepSpec
previewSpec horizon withFli =
  { aMin: 0.30, aMax: 0.85, eMin: 0.0, eMax: 0.35
  , cols: 120, rows: 75, horizonPeriods: horizon, mu: 9.54e-4, withFli
  }

fullSpec :: Number -> Boolean -> SweepSpec
fullSpec horizon withFli = (previewSpec horizon withFli) { cols = 240, rows = 150 }

-- Mean-motion resonances with Jupiter: a = (q/p)^(2/3) for p:q.
resonances :: Array { label :: String, a :: Number }
resonances =
  [ { label: "3:1", a: pow (1.0 / 3.0) (2.0 / 3.0) }
  , { label: "5:2", a: pow (2.0 / 5.0) (2.0 / 3.0) }
  , { label: "7:3", a: pow (3.0 / 7.0) (2.0 / 3.0) }
  , { label: "2:1", a: pow (1.0 / 2.0) (2.0 / 3.0) }
  , { label: "5:3", a: pow (3.0 / 5.0) (2.0 / 3.0) }
  , { label: "7:5", a: pow (5.0 / 7.0) (2.0 / 3.0) }
  ]

data Phase
  = Connecting
  | PreviewRunning
  | FullRunning
  | Done
  | SocketLost

phaseLabel :: Phase -> String
phaseLabel = case _ of
  Connecting -> "connecting to the Julia service…"
  PreviewRunning -> "preview sweep streaming (120 × 75)"
  FullRunning -> "full sweep streaming (240 × 150)"
  Done -> "sweep complete"
  SocketLost -> "service connection lost — is atlas-service running on :3210?"

type Selection = { a :: Number, e :: Number }

-- | Which frame the orrery draws in. The rotating frame is the CR3BP's
-- | native one (Jupiter pinned); the inertial frame un-rotates by t and
-- | shows the osculating Kepler ellipse precessing.
data FrameView = Rotating | Inertial

type State =
  { phase :: Phase
  , socket :: Maybe WS.WebSocket
  , spec :: SweepSpec
  , horizon :: Number
  , blocks :: Int
  , serverMs :: Maybe Number
  , selection :: Maybe Selection
  , frames :: Array Frame
  , trajLive :: Boolean
  , animIx :: Int
  , frameView :: FrameView
  , fli :: Boolean
  }

data Action
  = Initialize
  | SocketOpened
  | SocketMessage String
  | SocketClosed
  | CanvasClick MouseEvent
  | SetHorizon String
  | Rerun
  | ToggleFli
  | ToggleFrameView
  | Tick

component :: forall query input output. H.Component query input output Aff
component =
  H.mkComponent
    { initialState: \_ ->
        { phase: Connecting
        , socket: Nothing
        , spec: previewSpec 150.0 false
        , horizon: 150.0
        , blocks: 0
        , serverMs: Nothing
        , selection: Nothing
        , frames: []
        , trajLive: false
        , animIx: 0
        , frameView: Rotating
        , fli: false
        }
    , render
    , eval: H.mkEval H.defaultEval
        { handleAction = handleAction
        , initialize = Just Initialize
        }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div [ HP.class_ (HH.ClassName "atlas") ]
    [ HH.header_
        [ HH.h1_ [ HH.text "The Stability Atlas" ]
        , HH.p [ HP.class_ (HH.ClassName "thesis") ]
            [ HH.text "Each pixel is a real orbit integration of a test asteroid in the Sun–Jupiter three-body problem, computed by PureScript compiled to Julia and streamed here over a typed WebSocket. Dark means the asteroid was lost — ejected or swept into Jupiter's Hill sphere." ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "controls") ]
        [ HH.label_
            [ HH.text "horizon "
            , HH.select [ HE.onValueChange SetHorizon ]
                (map horizonOption [ "50", "150", "300" ])
            , HH.text " Jupiter periods" ]
        , HH.button [ HE.onClick \_ -> Rerun ] [ HH.text "re-run sweep" ]
        , HH.label_
            [ HH.input [ HP.type_ HP.InputCheckbox, HP.checked st.fli, HE.onChecked \_ -> ToggleFli ]
            , HH.text " chaos layer (FLI) — colours survivors by Lyapunov growth, ~2× slower" ]
        , HH.span [ HP.class_ (HH.ClassName "status") ]
            [ HH.text (phaseLabel st.phase <> statusDetail) ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "plot") ]
        [ HH.div [ HP.class_ (HH.ClassName "resonance-rail") ] (map resonanceMark resonances)
        , HH.canvas
            [ HP.id "atlas-canvas"
            , HP.ref (H.RefLabel "atlas-canvas")
            , HP.width (floor canvasW)
            , HP.height (floor canvasH)
            , HE.onClick CanvasClick
            ]
        , HH.div [ HP.class_ (HH.ClassName "x-axis") ]
            [ HH.span_ [ HH.text "a = 0.30 (1.56 AU)" ]
            , HH.span_ [ HH.text "semi-major axis" ]
            , HH.span_ [ HH.text "a = 0.85 (4.42 AU)" ]
            ]
        , HH.div [ HP.class_ (HH.ClassName "y-axis") ]
            [ HH.span_ [ HH.text "e = 0.35" ], HH.span_ [ HH.text "eccentricity" ], HH.span_ [ HH.text "e = 0" ] ]
        ]
    , HH.p [ HP.class_ (HH.ClassName "selection") ] [ HH.text selectionText ]
    , HH.div [ HP.class_ (HH.ClassName "orrery") ]
        [ HH.div [ HP.class_ (HH.ClassName "orrery-head") ]
            [ HH.h2_ [ HH.text "Orrery" ]
            , HH.button [ HE.onClick \_ -> ToggleFrameView ]
                [ HH.text case st.frameView of
                    Rotating -> "rotating frame (Jupiter pinned) — switch"
                    Inertial -> "inertial frame — switch"
                ]
            , HH.span [ HP.class_ (HH.ClassName "drift") ] [ HH.text driftText ]
            ]
        , HH.canvas
            [ HP.id "orrery-canvas"
            , HP.width 420
            , HP.height 420
            ]
        ]
    ]
  where
  driftText = case Array.head st.frames of
    Nothing -> "click an atlas pixel to stream its orbit from Julia"
    Just f0 ->
      let drift = Array.foldl (\m f -> max m (abs (f.jacobi - f0.jacobi))) 0.0 st.frames
      in show (Array.length st.frames) <> " frames · Jacobi drift "
           <> toStringWith (exponential 2) (drift / abs f0.jacobi)
           <> (if st.trajLive then " · streaming…" else "")
  statusDetail = case st.phase, st.serverMs of
    Done, Just ms -> " — " <> show st.blocks <> " blocks, " <> toStringWith (fixed 0) ms <> " ms in Julia"
    _, _ -> case st.blocks of
      0 -> ""
      n -> " — block " <> show n
  selectionText = case st.selection of
    Nothing -> "Click a pixel to stream that orbit into the orrery below."
    Just s -> "Selected: a = " <> toStringWith (fixed 4) s.a
      <> " (" <> toStringWith (fixed 2) (s.a * 5.2035) <> " AU), e = "
      <> toStringWith (fixed 3) s.e
  horizonOption v =
    HH.option [ HP.value v, HP.selected (v == toStringWith (fixed 0) st.horizon) ] [ HH.text v ]
  resonanceMark r =
    let frac = (r.a - 0.30) / (0.85 - 0.30)
    in HH.span
        [ HP.class_ (HH.ClassName "mark")
        , HP.style ("left:" <> toStringWith (fixed 2) (frac * 100.0) <> "%")
        ]
        [ HH.text r.label ]

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  Initialize -> do
    { emitter, listener } <- H.liftEffect HS.create
    void (H.subscribe emitter)
    socket <- H.liftEffect do
      ws <- WS.create serviceUrl []
      let target = WS.toEventTarget ws
      openL <- eventListener \_ -> HS.notify listener SocketOpened
      msgL <- eventListener (notifyMessage listener)
      closeL <- eventListener \_ -> HS.notify listener SocketClosed
      addEventListener WSE.onOpen openL false target
      addEventListener WSE.onMessage msgL false target
      addEventListener WSE.onClose closeL false target
      void (Timer.setInterval 33 (HS.notify listener Tick))
      pure ws
    H.modify_ _ { socket = Just socket }

  SocketOpened -> do
    st <- H.get
    let spec = previewSpec st.horizon st.fli
    H.modify_ _ { phase = PreviewRunning, spec = spec, blocks = 0, serverMs = Nothing }
    sendMsg (RequestSweep spec)

  SocketMessage raw -> case decodeServerMsg raw of
    Left err -> H.liftEffect (warn ("undecodable ServerMsg: " <> err))
    Right msg -> case msg of
      SweepRows block -> do
        st <- H.modify \s -> s { blocks = s.blocks + 1 }
        H.liftEffect (paintBlock st.spec block)
      SweepDone d -> do
        st <- H.get
        case st.phase of
          PreviewRunning -> do
            let spec = fullSpec st.horizon st.fli
            H.modify_ _ { phase = FullRunning, spec = spec, blocks = 0 }
            sendMsg (RequestSweep spec)
          _ -> H.modify_ _ { phase = Done, serverMs = Just d.elapsedMs }
      TrajFrames f -> do
        st <- H.modify \s -> s { frames = s.frames <> f.frames }
        H.liftEffect (paintOrrery st.frameView st.frames (Array.length st.frames - 1))
      TrajDone -> H.modify_ _ { trajLive = false }
      ProtocolError e -> H.liftEffect (warn ("service error: " <> e))

  SocketClosed -> H.modify_ _ { phase = SocketLost }

  CanvasClick ev -> do
    st <- H.get
    mEl <- H.getHTMLElementRef (H.RefLabel "atlas-canvas")
    for_ mEl \el -> do
      rect <- H.liftEffect (getBoundingClientRect (HTMLElement.toElement el))
      let px = toNumber (MouseEvent.clientX ev) - rect.left
      let py = toNumber (MouseEvent.clientY ev) - rect.top
      let s = st.spec
      let a = s.aMin + (s.aMax - s.aMin) * (px / canvasW)
      let e = s.eMin + (s.eMax - s.eMin) * (1.0 - py / canvasH)
      H.modify_ _ { selection = Just { a, e }, frames = [], animIx = 0, trajLive = true }
      sendMsg (RequestTrajectory { a, e, horizonPeriods: 30.0, mu: 9.54e-4, frameStride: 4 })

  SetHorizon v -> case v of
    "50" -> H.modify_ _ { horizon = 50.0 }
    "300" -> H.modify_ _ { horizon = 300.0 }
    _ -> H.modify_ _ { horizon = 150.0 }

  Rerun -> do
    st <- H.get
    let spec = previewSpec st.horizon st.fli
    H.modify_ _ { phase = PreviewRunning, spec = spec, blocks = 0, serverMs = Nothing }
    sendMsg (RequestSweep spec)

  ToggleFli -> do
    st <- H.modify \s -> s { fli = not s.fli }
    let spec = previewSpec st.horizon st.fli
    H.modify_ _ { phase = PreviewRunning, spec = spec, blocks = 0, serverMs = Nothing }
    sendMsg (RequestSweep spec)

  ToggleFrameView -> do
    st <- H.modify \s -> s
      { frameView = case s.frameView of
          Rotating -> Inertial
          Inertial -> Rotating
      }
    H.liftEffect (paintOrrery st.frameView st.frames st.animIx)

  Tick -> do
    st <- H.get
    let n = Array.length st.frames
    when (n > 1 && not st.trajLive) do
      let ix = mod (st.animIx + max 1 (n / 450)) n
      H.modify_ _ { animIx = ix }
      H.liftEffect (paintOrrery st.frameView st.frames ix)
  where
  sendMsg :: ClientMsg -> H.HalogenM State Action () output Aff Unit
  sendMsg msg = do
    st <- H.get
    for_ st.socket \ws -> H.liftEffect (WS.sendString ws (encodeClientMsg msg))

  notifyMessage :: HS.Listener Action -> Event -> Effect Unit
  notifyMessage listener ev =
    for_ (MessageEvent.fromEvent ev) \me ->
      case runExcept (readString (MessageEvent.data_ me)) of
        Right str -> HS.notify listener (SocketMessage str)
        Left _ -> pure unit

-- | Paint one row block. Verdict v ∈ [0,1] (survival fraction of the
-- | horizon): stable orbits fade to paper, lost orbits darken to ink —
-- | the gaps draw themselves as dark strokes.
paintBlock :: SweepSpec -> { rowStart :: Int, rows :: Array (Array Number) } -> Effect Unit
paintBlock spec block = do
  mCanvas <- GC.getCanvasElementById "atlas-canvas"
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    let cw = canvasW / toNumber spec.cols
    let ch = canvasH / toNumber spec.rows
    void (Array.foldM (paintRow ctx cw ch) (block.rowStart) block.rows)
  where
  paintRow ctx cw ch r row = do
    forWithIndex_ row \ci v -> do
      GC.setFillStyle ctx (verdictColor v)
      GC.fillRect ctx
        { x: toNumber ci * cw
        , y: canvasH - toNumber (r + 1) * ch
        , width: cw + 0.5
        , height: ch + 0.5
        }
    pure (r + 1)

  -- v < 1: lost, ink ramp by how fast. v ≥ 1: survived; (v−1) is the
  -- normalized FLI. Measured distribution across the belt (150 periods):
  -- the regular continuum (Keplerian shear) spans FLI 3–5 (p50 4.4,
  -- p90 5.1) and chaos saturates at the cap 8 — so the rust ramp starts
  -- just above p90 (0.66 normalized) and quasi-periodic pixels stay paper.
  verdictColor v
    | v < 1.0 =
        let t = pow (1.0 - v) 0.55
            lerp lo hi = floor (lo + (hi - lo) * t)
        in "rgb(" <> show (lerp 244.0 16.0) <> "," <> show (lerp 242.0 42.0) <> "," <> show (lerp 236.0 84.0) <> ")"
    | otherwise =
        let t = min 1.0 (max 0.0 ((v - 1.0 - 0.66) / 0.34))
            lerp lo hi = floor (lo + (hi - lo) * pow t 0.8)
        in "rgb(" <> show (lerp 244.0 193.0) <> "," <> show (lerp 242.0 84.0) <> "," <> show (lerp 236.0 44.0) <> ")"

-- | Draw the orrery: bodies, the streamed trail, the current-frame dot —
-- | in the rotating frame (Jupiter pinned) or the inertial one (the
-- | osculating Kepler ellipse appears, precessing).
paintOrrery :: FrameView -> Array Frame -> Int -> Effect Unit
paintOrrery view frames ix = do
  mCanvas <- GC.getCanvasElementById "orrery-canvas"
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    GC.setFillStyle ctx "#eceae3"
    GC.fillRect ctx { x: 0.0, y: 0.0, width: size, height: size }
    let cur = fromMaybe { t: 0.0, x: 0.0, y: 0.0, vx: 0.0, vy: 0.0, jacobi: 0.0 } (Array.index frames ix)
    let sunP = project view cur.t { wx: -mu, wy: 0.0 }
    let jupP = project view cur.t { wx: 1.0 - mu, wy: 0.0 }
    -- Hill zone marker around Jupiter
    let rh = pow (mu / 3.0) (1.0 / 3.0) * scale
    GC.setStrokeStyle ctx "#c1542c"
    GC.setLineWidth ctx 0.75
    GC.strokeRect ctx { x: jupP.px - rh, y: jupP.py - rh, width: 2.0 * rh, height: 2.0 * rh }
    -- trail
    case Array.head frames of
      Nothing -> pure unit
      Just f0 -> do
        GC.setStrokeStyle ctx "#14213d"
        GC.setLineWidth ctx 1.0
        GC.beginPath ctx
        let p0 = projectF view f0
        GC.moveTo ctx p0.px p0.py
        for_ frames \f -> do
          let p = projectF view f
          GC.lineTo ctx p.px p.py
        GC.stroke ctx
    -- bodies (squares; the Swiss orrery)
    GC.setFillStyle ctx "#d9a521"
    GC.fillRect ctx { x: sunP.px - 5.0, y: sunP.py - 5.0, width: 10.0, height: 10.0 }
    GC.setFillStyle ctx "#c1542c"
    GC.fillRect ctx { x: jupP.px - 3.5, y: jupP.py - 3.5, width: 7.0, height: 7.0 }
    -- the asteroid now
    let pNow = projectF view cur
    GC.setFillStyle ctx "#1a6b4a"
    GC.fillRect ctx { x: pNow.px - 3.0, y: pNow.py - 3.0, width: 6.0, height: 6.0 }
  where
  size = 420.0
  scale = 150.0
  center = size / 2.0
  mu = 9.54e-4

  projectF v f = project v f.t { wx: f.x, wy: f.y }

  -- Rotating-frame world coords; inertial = rotate by +t (canvas y flips).
  project v t w = case v of
    Rotating -> { px: center + w.wx * scale, py: center - w.wy * scale }
    Inertial ->
      { px: center + (w.wx * cos t - w.wy * sin t) * scale
      , py: center - (w.wx * sin t + w.wy * cos t) * scale
      }
