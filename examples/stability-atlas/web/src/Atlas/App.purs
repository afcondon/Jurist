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

import Atlas.Dynamics as Dyn
import Atlas.Protocol (ClientMsg(..), Frame, ServerMsg(..), SweepSpec, decodeServerMsg, encodeClientMsg)
import Control.Monad.Except (runExcept)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.FoldableWithIndex (forWithIndex_)
import Data.Int (floor, toNumber)
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (for)
import Effect.Random (random)
import Data.Number (abs, cos, log, pi, pow, sin, sqrt)
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

-- Trajectory request parameters, shared by the request and the honesty
-- meter's lockstep mirror of the service loop.
trajStride :: Int
trajStride = 4

trajHorizonPeriods :: Number
trajHorizonPeriods = 30.0

-- | The honesty meter. When an orbit streams in from Julia, the browser
-- | re-runs it with the SAME `Atlas.Dynamics` — this module compiled to
-- | JavaScript instead of Julia — stepping in lockstep with the incoming
-- | frames. `fine` mirrors the service loop exactly (same dt, same stride,
-- | same loss check): any nonzero divergence means the two runtimes
-- | disagree about IEEE-754 arithmetic. `coarse` integrates the same orbit
-- | at stride× the step so the chart also shows what honest numerical
-- | error looks like — drift belongs to the integrator's dial, not to the
-- | runtime.
type Meter =
  { mu :: Number
  , dt :: Number
  , fine :: Dyn.State
  , fineAlive :: Boolean
  , coarse :: Dyn.State
  , jac0 :: Number
  , maxDiff :: Number
  , frames :: Int
  , points :: Array MeterPoint
  }

-- | Relative Jacobi drift |C(t) − C(0)| / |C(0)| per runtime, one point
-- | per streamed frame.
type MeterPoint = { t :: Number, julia :: Number, fine :: Number, coarse :: Number }

initMeter :: Number -> Number -> Number -> Meter
initMeter mu a e =
  let s0 = Dyn.initialState mu a e
  in
    { mu
    , dt: Dyn.asteroidPeriod a / Dyn.stepsPerPeriod
    , fine: s0
    , fineAlive: true
    , coarse: s0
    , jac0: Dyn.jacobi mu s0
    , maxDiff: 0.0
    , frames: 0
    , points: []
    }

-- | Fold one streamed frame into the meter: advance both browser
-- | integrators to the frame's time, compare against what Julia sent.
meterStep :: Meter -> Frame -> Meter
meterStep m f
  -- The head frame is the initial state, before any integration: the
  -- comparison here checks initialState plus the wire round-trip.
  | f.t == 0.0 = m
      { maxDiff = max m.maxDiff (frameDiff m.mu m.fine f)
      , frames = m.frames + 1
      , points = [ { t: 0.0, julia: relDrift m f.jacobi, fine: 0.0, coarse: 0.0 } ]
      }
  | otherwise =
      let
        fine' = if m.fineAlive then advanceFine m else { s: m.fine, alive: false }
        coarse' = Dyn.rk4Step m.mu (m.dt * toNumber trajStride) m.coarse
      in m
        { fine = fine'.s
        , fineAlive = fine'.alive
        , coarse = coarse'
        , maxDiff = max m.maxDiff (frameDiff m.mu fine'.s f)
        , frames = m.frames + 1
        , points = m.points <>
            [ { t: f.t
              , julia: relDrift m f.jacobi
              , fine: relDrift m (Dyn.jacobi m.mu fine'.s)
              , coarse: relDrift m (Dyn.jacobi m.mu coarse')
              }
            ]
        }

relDrift :: Meter -> Number -> Number
relDrift m j = abs (j - m.jac0) / abs m.jac0

-- | Largest absolute disagreement between the browser's state and the
-- | streamed frame, across all four state components and the Jacobi
-- | constant. Zero means bit-identical.
frameDiff :: Number -> Dyn.State -> Frame -> Number
frameDiff mu s f =
  abs (s.x - f.x)
    `max` abs (s.y - f.y)
    `max` abs (s.vx - f.vx)
    `max` abs (s.vy - f.vy)
    `max` abs (Dyn.jacobi mu s - f.jacobi)

-- | One frame's worth of fine integration: stride steps with the same
-- | loss check the service loop runs, stopping where it stops. (The Hill
-- | threshold uses pow, which may differ by an ulp across runtimes — it
-- | only gates the comparison, never enters the integrated state, and a
-- | mismatch would surface honestly as a divergence on the final frame.)
advanceFine :: Meter -> { s :: Dyn.State, alive :: Boolean }
advanceFine m = go trajStride m.fine
  where
  rHillSq = pow (m.mu / 3.0) (2.0 / 3.0)
  go :: Int -> Dyn.State -> { s :: Dyn.State, alive :: Boolean }
  go n s = case n of
    0 -> { s, alive: true }
    _ ->
      let
        s' = Dyn.rk4Step m.mu m.dt s
        dx1 = s'.x + m.mu
        dx2 = s'.x - 1.0 + m.mu
        r1sq = dx1 * dx1 + s'.y * s'.y
        r2sq = dx2 * dx2 + s'.y * s'.y
      in
        if r1sq > Dyn.escapeRadius * Dyn.escapeRadius || r2sq < rHillSq
        then { s: s', alive: false }
        else go (n - 1) s'

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

-- | A "small multiple": one asteroid's orbit, integrated entirely in the
-- | browser by `Atlas.Dynamics` — the same code the honesty meter proved
-- | bit-identical to the Julia service. `pts` are rotating-frame samples
-- | (the inertial view un-rotates them by t at paint time). `verdict` is
-- | the survived-fraction of the window: 1.0 = lasted the whole time.
type Mini =
  { a :: Number
  , e :: Number
  , verdict :: Number
  , pts :: Array { t :: Number, x :: Number, y :: Number }
  }

-- How long each small multiple runs, in Jupiter periods: long enough for a
-- resonant orbit to close its rosette and a doomed one to wander off,
-- short enough that the figure stays legible.
miniPeriods :: Number
miniPeriods = 16.0

-- Sample every this-many RK4 steps when building a small multiple's trail.
miniStride :: Int
miniStride = 3

-- | Integrate one asteroid in the browser and collect its rotating-frame
-- | trail, stopping early (with a fractional verdict) if it escapes the
-- | Sun's grip or falls into Jupiter's Hill sphere.
computeMini :: Number -> Number -> Number -> Mini
computeMini mu a e =
  let
    dt = Dyn.asteroidPeriod a / Dyn.stepsPerPeriod
    horizon = miniPeriods * 2.0 * pi
    rHillSq = pow (mu / 3.0) (2.0 / 3.0)
    rEscSq = Dyn.escapeRadius * Dyn.escapeRadius
    lost s =
      let dx1 = s.x + mu
          dx2 = s.x - 1.0 + mu
      in dx1 * dx1 + s.y * s.y > rEscSq || dx2 * dx2 + s.y * s.y < rHillSq
    stride n s t = case n of
      0 -> { s, t, alive: true }
      _ ->
        let s' = Dyn.rk4Step mu dt s
            t' = t + dt
        in if lost s' then { s: s', t: t', alive: false }
           else stride (n - 1) s' t'
    collect s t acc =
      if t >= horizon then { verdict: 1.0, pts: acc }
      else
        let r = stride miniStride s t
            acc' = { t: r.t, x: r.s.x, y: r.s.y } : acc
        in if r.alive then collect r.s r.t acc'
           else { verdict: r.t / horizon, pts: acc' }
    s0 = Dyn.initialState mu a e
    res = collect s0 0.0 ({ t: 0.0, x: s0.x, y: s0.y } : Nil)
  in
    { a, e, verdict: res.verdict, pts: Array.reverse (List.toUnfoldable res.pts) }

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
  , meter :: Maybe Meter
  , minis :: Array Mini
  , minisPainted :: Boolean
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
  | SelectPick Selection
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
        , meter: Nothing
        , minis: []
        , minisPainted: false
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
    , HH.div [ HP.class_ (HH.ClassName "key") ]
        [ HH.div [ HP.class_ (HH.ClassName "orrery-head") ]
            [ HH.h2_ [ HH.text "How to read the atlas" ] ]
        , HH.p [ HP.class_ (HH.ClassName "key-lede") ]
            [ HH.text "Every pixel in the atlas below is one test asteroid. We place it on a starting orbit — its position left-to-right sets the "
            , HH.strong_ [ HH.text "semi-major axis" ]
            , HH.text " (the orbit's size), bottom-to-top sets the "
            , HH.strong_ [ HH.text "eccentricity" ]
            , HH.text " (how stretched the orbit is) — then integrate its motion in the Sun–Jupiter system for many Jupiter orbits and ask whether it survives. Pale means it survived; dark means Jupiter ejected it or swallowed it into its Hill sphere — the darker, the sooner. The dark vertical lanes fall at "
            , HH.strong_ [ HH.text "mean-motion resonances" ]
            , HH.text " (the ticks above the plot: 2:1, 3:1, …) — orbits whose period is a simple fraction of Jupiter's, so its gravitational tug repeats in phase and pumps them out. Those are the Kirkwood gaps: real empty lanes in the asteroid belt." ]
        , HH.canvas
            [ HP.id "key-canvas"
            , HP.width (floor keyW)
            , HP.height (floor keyH)
            ]
        , HH.p [ HP.class_ (HH.ClassName "key-caption") ]
            [ HH.text "One asteroid's orbit (ink) around the Sun, inside Jupiter's orbit (rust). The "
            , HH.strong_ [ HH.text "semi-major axis a" ]
            , HH.text " — the orbit's half-width — is the atlas's horizontal axis. The "
            , HH.strong_ [ HH.text "eccentricity e" ]
            , HH.text " — how far the orbit departs from the dashed circle of the same size — is the vertical axis. (Eccentricity is exaggerated here for clarity; the atlas runs e from 0 to 0.35.)" ]
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
    , HH.div [ HP.class_ (HH.ClassName "multiples") ]
        [ HH.div [ HP.class_ (HH.ClassName "orrery-head") ]
            [ HH.h2_ [ HH.text "Eight orbits, two ways" ] ]
        , HH.p [ HP.class_ (HH.ClassName "key-lede") ]
            [ HH.text "Eight asteroids picked at random across the belt — the red squares on the atlas above — each integrated right here in your browser by the same "
            , HH.strong_ [ HH.text "Atlas.Dynamics" ]
            , HH.text ". Top of each pair is the "
            , HH.strong_ [ HH.text "inertial frame" ]
            , HH.text " (the view from the fixed stars), where every orbit is a near-identical Kepler ellipse. Below it is the "
            , HH.strong_ [ HH.text "rotating frame" ]
            , HH.text " (co-rotating with Jupiter), where the same orbits reveal their character: resonant ones close into petalled rosettes, quasi-periodic ones fill a band, and the doomed ones wander off before the window ends. Same physics, same data — only the camera differs. Click any to stream it from Julia into the orrery below." ]
        , HH.div [ HP.class_ (HH.ClassName "mini-rowlabel") ] [ HH.text "Inertial — seen from the fixed stars" ]
        , HH.div [ HP.class_ (HH.ClassName "mini-row") ] (Array.mapWithIndex (miniCanvas "i") st.minis)
        , HH.div [ HP.class_ (HH.ClassName "mini-rowlabel") ] [ HH.text "Rotating — co-rotating with Jupiter" ]
        , HH.div [ HP.class_ (HH.ClassName "mini-row") ] (Array.mapWithIndex (miniCanvas "r") st.minis)
        , HH.div [ HP.class_ (HH.ClassName "mini-caprow") ] (Array.mapWithIndex miniCap st.minis)
        ]
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
    , HH.div [ HP.class_ (HH.ClassName "meter") ]
        [ HH.div [ HP.class_ (HH.ClassName "orrery-head") ]
            [ HH.h2_ [ HH.text "Honesty meter" ]
            , HH.span [ HP.class_ (HH.ClassName "drift") ] [ HH.text meterText ]
            ]
        , HH.p [ HP.class_ (HH.ClassName "meter-lede") ]
            [ HH.text "The orbit above was computed by Julia. This browser re-runs it with the same Atlas.Dynamics module — compiled to JavaScript here, to Julia there. Ink line: Jacobi drift of the Julia stream. Green squares: the browser at the same step size — they sit exactly on the ink when the two runtimes agree to the last bit. Rust line: the browser at 4× the step size, for scale — that gap is what numerical error looks like; the runtimes contribute none." ]
        , HH.canvas
            [ HP.id "meter-canvas"
            , HP.width (floor meterW)
            , HP.height (floor meterH)
            ]
        ]
    ]
  where
  meterText = case st.meter of
    Nothing -> "click an atlas pixel — the browser will re-run the same physics"
    Just m | m.frames == 0 -> "waiting for frames…"
    Just m ->
      "browser vs Julia at the same dt: " <>
        if m.maxDiff == 0.0
        then "bit-identical across " <> show m.frames <> " frames (max |Δ| = 0)"
        else "max |Δ| = " <> toStringWith (exponential 2) m.maxDiff
               <> " across " <> show m.frames <> " frames"
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
  miniCanvas pre i m =
    HH.canvas
      [ HP.id ("mini-" <> pre <> "-" <> show i)
      , HP.class_ (HH.ClassName "mini")
      , HP.width (floor miniSize)
      , HP.height (floor miniSize)
      , HE.onClick \_ -> SelectPick { a: m.a, e: m.e }
      ]
  miniCap i m =
    HH.div [ HP.class_ (HH.ClassName "cap") ]
      [ HH.strong_ [ HH.text (show (i + 1)) ]
      , HH.text (" a " <> toStringWith (fixed 2) m.a <> " · e " <> toStringWith (fixed 2) m.e)
      , HH.br_
      , HH.span [ HP.class_ (HH.ClassName (if m.verdict >= 1.0 then "ok" else "lost")) ]
          [ HH.text
              ( if m.verdict >= 1.0 then "survived"
                else "lost @ " <> toStringWith (fixed 0) (m.verdict * miniPeriods) <> "p" )
          ]
      ]

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  Initialize -> do
    { emitter, listener } <- H.liftEffect HS.create
    void (H.subscribe emitter)
    -- Pick eight asteroids — one at a random eccentricity in each of eight
    -- equal bands across the swept range of a, so the sample always spans
    -- the resonances on the right — and integrate each in the browser.
    minis <- H.liftEffect do
      let band = (0.85 - 0.30) / 8.0
      picks <- for (Array.range 0 7) \i -> do
        ra <- random
        re <- random
        pure { a: 0.30 + (toNumber i + ra) * band, e: re * 0.35 }
      pure (map (\p -> computeMini 9.54e-4 p.a p.e) picks)
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
    H.modify_ _ { socket = Just socket, minis = minis }
    H.liftEffect paintKey

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
          _ -> do
            H.modify_ _ { phase = Done, serverMs = Just d.elapsedMs }
            H.liftEffect (paintPickMarkers st.spec st.minis)
      TrajFrames f -> do
        st <- H.modify \s -> s
          { frames = s.frames <> f.frames
          , meter = map (\m -> Array.foldl meterStep m f.frames) s.meter
          }
        H.liftEffect (paintOrrery st.frameView st.frames (Array.length st.frames - 1))
        H.liftEffect (for_ st.meter paintMeter)
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
      H.modify_ _
        { selection = Just { a, e }
        , frames = []
        , animIx = 0
        , trajLive = true
        , meter = Just (initMeter 9.54e-4 a e)
        }
      sendMsg (RequestTrajectory { a, e, horizonPeriods: trajHorizonPeriods, mu: 9.54e-4, frameStride: trajStride })

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

  SelectPick sel -> do
    H.modify_ _
      { selection = Just sel
      , frames = []
      , animIx = 0
      , trajLive = true
      , meter = Just (initMeter 9.54e-4 sel.a sel.e)
      }
    sendMsg (RequestTrajectory { a: sel.a, e: sel.e, horizonPeriods: trajHorizonPeriods, mu: 9.54e-4, frameStride: trajStride })

  Tick -> do
    st <- H.get
    -- One-shot paint of the small multiples, once their canvases exist in
    -- the DOM (they appear only after `minis` is populated and rendered).
    when (not st.minisPainted && not (Array.null st.minis)) do
      mc <- H.liftEffect (GC.getCanvasElementById "mini-i-0")
      for_ mc \_ -> do
        H.liftEffect $ forWithIndex_ st.minis \i m -> do
          paintMini ("mini-i-" <> show i) Inertial m
          paintMini ("mini-r-" <> show i) Rotating m
        H.modify_ _ { minisPainted = true }
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

meterW :: Number
meterW = 720.0

meterH :: Number
meterH = 170.0

-- | The honesty-meter strip chart: relative Jacobi drift against time on
-- | a log scale. Decade gridlines; the Julia stream in ink, the browser's
-- | same-dt mirror as green squares riding it, the browser's 4×-dt run in
-- | rust above both.
paintMeter :: Meter -> Effect Unit
paintMeter m = do
  mCanvas <- GC.getCanvasElementById "meter-canvas"
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    GC.setFillStyle ctx "#eceae3"
    GC.fillRect ctx { x: 0.0, y: 0.0, width: meterW, height: meterH }
    -- decade gridlines
    GC.setFont ctx "10px 'Helvetica Neue', Helvetica, sans-serif"
    for_ [ -16, -14, -12, -10, -8, -6, -4, -2 ] \dec -> do
      let y = yOf (pow 10.0 (toNumber dec))
      GC.setStrokeStyle ctx "#d8d4ca"
      GC.setLineWidth ctx 0.5
      GC.beginPath ctx
      GC.moveTo ctx padL y
      GC.lineTo ctx (meterW - padR) y
      GC.stroke ctx
      GC.setFillStyle ctx "#6e6a60"
      GC.fillText ctx ("1e" <> show dec) 4.0 (y + 3.0)
    GC.setFillStyle ctx "#6e6a60"
    GC.fillText ctx "0" padL (meterH - 6.0)
    GC.fillText ctx (toStringWith (fixed 0) trajHorizonPeriods <> " Jupiter periods")
      (meterW - padR - 110.0) (meterH - 6.0)
    -- traces: coarse beneath, Julia on top of it, fine dots above all —
    -- when the runtimes agree bit for bit the dots sit exactly on the ink
    polyline ctx "#c1542c" (\p -> p.coarse)
    polyline ctx "#14213d" (\p -> p.julia)
    GC.setFillStyle ctx "#1a6b4a"
    forWithIndex_ m.points \i p ->
      when (mod i 25 == 0) do
        GC.fillRect ctx { x: xOf p.t - 1.5, y: yOf p.fine - 1.5, width: 3.0, height: 3.0 }
  where
  padL = 44.0
  padR = 12.0
  padT = 10.0
  padB = 22.0

  tMax = trajHorizonPeriods * 2.0 * pi

  xOf t = padL + (t / tMax) * (meterW - padL - padR)

  -- log10 scale over [1e-16, 1e-2]; zero drift clamps to the floor
  yOf d =
    let
      l = max (-16.0) (min (-2.0) (log (max d 1.0e-300) / log 10.0))
      frac = (-2.0 - l) / 14.0
    in padT + frac * (meterH - padT - padB)

  polyline ctx color value = case Array.head m.points of
    Nothing -> pure unit
    Just p0 -> do
      GC.setStrokeStyle ctx color
      GC.setLineWidth ctx 1.25
      GC.beginPath ctx
      GC.moveTo ctx (xOf p0.t) (yOf (value p0))
      for_ m.points \p -> GC.lineTo ctx (xOf p.t) (yOf (value p))
      GC.stroke ctx

keyW :: Number
keyW = 720.0

keyH :: Number
keyH = 330.0

-- | A static schematic that anchors the atlas's two axes to real orbit
-- | geometry: the Sun, one test asteroid on an elliptical orbit, and
-- | Jupiter on its near-circular orbit outside it. The orbit's semi-major
-- | axis a (its half-width) is the atlas's horizontal axis; its
-- | eccentricity e — how far it departs from the dashed same-size circle —
-- | is the vertical axis. Eccentricity is drawn exaggerated (≈0.5) for
-- | legibility; the atlas sweeps e ∈ [0, 0.35]. Painted once, on init.
paintKey :: Effect Unit
paintKey = do
  mCanvas <- GC.getCanvasElementById "key-canvas"
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    GC.setFillStyle ctx "#fbfaf7"
    GC.fillRect ctx { x: 0.0, y: 0.0, width: keyW, height: keyH }

    -- Jupiter's orbit (dashed rust circle) — drawn first, behind everything
    GC.setStrokeStyle ctx "#c1542c"
    GC.setLineWidth ctx 1.0
    GC.setLineDash ctx [ 5.0, 5.0 ]
    GC.beginPath ctx
    GC.arc ctx { x: sunX, y: sunY, radius: rJup, start: 0.0, end: 2.0 * pi, useCounterClockwise: false }
    GC.stroke ctx

    -- The e = 0 reference: a circle of the same semi-major axis, centred on
    -- the Sun. The ellipse's departure from it is the eccentricity.
    GC.setStrokeStyle ctx "#b9b4a8"
    GC.setLineWidth ctx 1.0
    GC.setLineDash ctx [ 3.0, 4.0 ]
    GC.beginPath ctx
    GC.arc ctx { x: sunX, y: sunY, radius: aPx, start: 0.0, end: 2.0 * pi, useCounterClockwise: false }
    GC.stroke ctx
    GC.setLineDash ctx []

    -- The asteroid's elliptical orbit (Sun at the right focus)
    GC.setStrokeStyle ctx "#14213d"
    GC.setLineWidth ctx 1.5
    GC.beginPath ctx
    GC.moveTo ctx (cx + aPx) cy
    for_ (Array.range 1 96) \i -> do
      let th = 2.0 * pi * toNumber i / 96.0
      GC.lineTo ctx (cx + aPx * cos th) (cy - bPx * sin th)
    GC.stroke ctx

    -- Major axis (faint) + the centre cross
    GC.setStrokeStyle ctx "#d8d4ca"
    GC.setLineWidth ctx 1.0
    GC.beginPath ctx
    GC.moveTo ctx (cx - aPx) cy
    GC.lineTo ctx (cx + aPx) cy
    GC.stroke ctx
    GC.setStrokeStyle ctx "#9a958a"
    GC.beginPath ctx
    GC.moveTo ctx (cx - 4.0) cy
    GC.lineTo ctx (cx + 4.0) cy
    GC.moveTo ctx cx (cy - 4.0)
    GC.lineTo ctx cx (cy + 4.0)
    GC.stroke ctx

    -- Bodies
    GC.setFillStyle ctx "#d9a521"
    GC.fillRect ctx { x: sunX - 6.0, y: sunY - 6.0, width: 12.0, height: 12.0 }
    GC.setFillStyle ctx "#c1542c"
    GC.fillRect ctx { x: jupX - 5.0, y: jupY - 5.0, width: 10.0, height: 10.0 }
    GC.setFillStyle ctx "#1a6b4a"
    GC.fillRect ctx { x: astX - 4.0, y: astY - 4.0, width: 8.0, height: 8.0 }

    -- Body + orbit labels
    GC.setFont ctx "13px 'Helvetica Neue', Helvetica, sans-serif"
    GC.setTextAlign ctx GC.AlignLeft
    GC.setFillStyle ctx "#14213d"
    GC.fillText ctx "Sun" (sunX + 11.0) (sunY + 5.0)
    GC.fillText ctx "Jupiter" (jupX + 11.0) (jupY + 4.0)
    GC.fillText ctx "asteroid" (astX - 66.0) (astY - 6.0)
    GC.setFont ctx "11px 'Helvetica Neue', Helvetica, sans-serif"
    GC.setFillStyle ctx "#6e6a60"
    GC.fillText ctx "Jupiter's orbit" (sunX + 16.0) (sunY - rJup + 16.0)
    GC.setTextAlign ctx GC.AlignCenter
    GC.fillText ctx "the same orbit at e = 0 (a circle)" sunX (sunY - aPx - 8.0)
    GC.fillText ctx "this orbit: e ≈ 0.66 (exaggerated)" (cx + aPx - 6.0) (cy + bPx + 16.0)

    -- Semi-major-axis dimension line (centre → perihelion), below the orbit
    let dimY = sunY + 118.0
    GC.setStrokeStyle ctx "#14213d"
    GC.setLineWidth ctx 1.0
    GC.setLineDash ctx [ 2.0, 3.0 ]
    GC.beginPath ctx
    GC.moveTo ctx cx cy
    GC.lineTo ctx cx dimY
    GC.moveTo ctx (cx + aPx) cy
    GC.lineTo ctx (cx + aPx) dimY
    GC.stroke ctx
    GC.setLineDash ctx []
    GC.beginPath ctx
    GC.moveTo ctx cx dimY
    GC.lineTo ctx (cx + aPx) dimY
    GC.stroke ctx
    GC.beginPath ctx
    GC.moveTo ctx cx (dimY - 4.0)
    GC.lineTo ctx cx (dimY + 4.0)
    GC.moveTo ctx (cx + aPx) (dimY - 4.0)
    GC.lineTo ctx (cx + aPx) (dimY + 4.0)
    GC.stroke ctx

    -- Axis-mapping callouts, in the accent colour
    GC.setFont ctx "13px 'Helvetica Neue', Helvetica, sans-serif"
    GC.setFillStyle ctx "#c1542c"
    GC.setTextAlign ctx GC.AlignCenter
    GC.fillText ctx "a — semi-major axis  =  the atlas's horizontal axis" (cx + aPx / 2.0) (dimY + 20.0)
    -- Vertical (eccentricity) callout, rotated up the left margin
    GC.save ctx
    GC.translate ctx { translateX: 22.0, translateY: keyH / 2.0 }
    GC.rotate ctx (-pi / 2.0)
    GC.fillText ctx "e — eccentricity  =  the atlas's vertical axis" 0.0 0.0
    GC.restore ctx
  where
  sunX = 360.0
  sunY = 158.0
  aPx = 76.0
  ecc = 0.66                            -- exaggerated: a real e this high is rare, but
                                        -- lower values look circular and teach nothing
  cPx = aPx * ecc                       -- focus offset = a·e
  bPx = aPx * sqrt (1.0 - ecc * ecc)    -- semi-minor axis
  cx = sunX - cPx                       -- ellipse centre (Sun at right focus)
  cy = sunY
  rJup = 150.0                          -- > aphelion distance (a + a·e = 126)
  astTheta = 2.4
  astX = cx + aPx * cos astTheta
  astY = cy - bPx * sin astTheta
  jupTheta = 0.62
  jupX = sunX + rJup * cos jupTheta
  jupY = sunY - rJup * sin jupTheta

miniSize :: Number
miniSize = 120.0

-- | Paint one small-multiple thumbnail: a single asteroid's orbit, in the
-- | rotating frame (Jupiter pinned, a fixed rust dot) or the inertial one
-- | (Jupiter's orbit a faint ring, the trail un-rotated by t). The Sun
-- | sits at the centre; the trail is a thin half-opacity ink stroke so
-- | overlapping loops read as density.
paintMini :: String -> FrameView -> Mini -> Effect Unit
paintMini canvasId view m = do
  mCanvas <- GC.getCanvasElementById canvasId
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    GC.setFillStyle ctx "#eceae3"
    GC.fillRect ctx { x: 0.0, y: 0.0, width: miniSize, height: miniSize }
    -- Jupiter reference: a ring (inertial) or a fixed dot (rotating)
    case view of
      Inertial -> do
        GC.setStrokeStyle ctx "#d8d4ca"
        GC.setLineWidth ctx 0.75
        GC.beginPath ctx
        GC.arc ctx { x: cx, y: cy, radius: scale, start: 0.0, end: 2.0 * pi, useCounterClockwise: false }
        GC.stroke ctx
      Rotating -> do
        let jp = project 0.0 (1.0 - mu) 0.0
        GC.setFillStyle ctx "#c1542c"
        GC.fillRect ctx { x: jp.px - 2.5, y: jp.py - 2.5, width: 5.0, height: 5.0 }
    -- the trail
    case Array.head m.pts of
      Nothing -> pure unit
      Just p0 -> do
        GC.setGlobalAlpha ctx 0.5
        GC.setStrokeStyle ctx "#14213d"
        GC.setLineWidth ctx 0.7
        GC.beginPath ctx
        let q0 = project p0.t p0.x p0.y
        GC.moveTo ctx q0.px q0.py
        for_ m.pts \p -> do
          let q = project p.t p.x p.y
          GC.lineTo ctx q.px q.py
        GC.stroke ctx
        GC.setGlobalAlpha ctx 1.0
    -- where the asteroid ended up (green; red if it was lost)
    for_ (Array.last m.pts) \pe -> do
      let qe = project pe.t pe.x pe.y
      GC.setFillStyle ctx (if m.verdict >= 1.0 then "#1a6b4a" else "#e02d2d")
      GC.fillRect ctx { x: qe.px - 2.0, y: qe.py - 2.0, width: 4.0, height: 4.0 }
    -- the Sun
    GC.setFillStyle ctx "#d9a521"
    GC.fillRect ctx { x: cx - 2.5, y: cy - 2.5, width: 5.0, height: 5.0 }
  where
  mu = 9.54e-4
  cx = miniSize / 2.0
  cy = miniSize / 2.0
  scale = (miniSize / 2.0 - 9.0) / 1.35
  project t wx wy = case view of
    Rotating -> { px: cx + wx * scale, py: cy - wy * scale }
    Inertial ->
      { px: cx + (wx * cos t - wy * sin t) * scale
      , py: cy - (wx * sin t + wy * cos t) * scale
      }

-- | Overlay the eight picked asteroids on the atlas as numbered red
-- | squares, after the full sweep has painted. Same (a, e) → pixel mapping
-- | the click handler uses, so the markers land exactly on their pixels.
paintPickMarkers :: SweepSpec -> Array Mini -> Effect Unit
paintPickMarkers spec minis = do
  mCanvas <- GC.getCanvasElementById "atlas-canvas"
  for_ mCanvas \canvas -> do
    ctx <- GC.getContext2D canvas
    GC.setFont ctx "bold 11px 'Helvetica Neue', Helvetica, sans-serif"
    GC.setTextAlign ctx GC.AlignCenter
    forWithIndex_ minis \i m -> do
      let x = (m.a - spec.aMin) / (spec.aMax - spec.aMin) * canvasW
          y = canvasH - (m.e - spec.eMin) / (spec.eMax - spec.eMin) * canvasH
      GC.setFillStyle ctx "#e02d2d"
      GC.fillRect ctx { x: x - 4.0, y: y - 4.0, width: 8.0, height: 8.0 }
      GC.setStrokeStyle ctx "#fbfaf7"
      GC.setLineWidth ctx 1.5
      GC.strokeRect ctx { x: x - 4.0, y: y - 4.0, width: 8.0, height: 8.0 }
      GC.setFillStyle ctx "#e02d2d"
      GC.fillText ctx (show (i + 1)) x (y - 9.0)
