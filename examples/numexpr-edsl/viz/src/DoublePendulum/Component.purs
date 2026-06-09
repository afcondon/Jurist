-- | A pure *player* of the Julia-computed double-pendulum trajectory. There is
-- | no physics here — the index-1 DAE was solved by ModelingToolkit on the Julia
-- | runtime (Jurist Tier-2 increment 4) and handed over as JSON frames. Each
-- | ~16ms tick advances a frame index and re-renders the two rigid rods, the
-- | three joints, and a fading trail of the second bob — the chaotic curve the
-- | browser could never have integrated itself.
-- |
-- | Rendering is Hylograph HATS: a declarative SVG tree (`HATS.elem` composed
-- | with `<>`) re-rendered into a container by `rerender`. Halogen owns only a
-- | static host `<div>`; HATS owns the SVG inside it.
module DoublePendulum.Component
  ( component
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import DoublePendulum.Fetch (loadTrajectory)
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Hylograph.HATS (Tree, elem) as HATS
import Hylograph.HATS.Friendly as F
import Hylograph.HATS.InterpreterTick (rerender) as IT
import Hylograph.Internal.Element.Types (ElementType(..))

-- ── Geometry ────────────────────────────────────────────────────────────────

-- pixels per physics unit (rods have length 1, bobs reach radius ~2)
scale :: Number
scale = 150.0

-- physics (x up-positive) → SVG canvas (y down-positive), pivot at origin
toCanvas :: Number -> Number -> Tuple Number Number
toCanvas x y = Tuple (x * scale) (negate y * scale)

-- how many recent bob-2 positions to keep in the trail (~13s at 60fps)
trailLen :: Int
trailLen = 800

-- ── Palette (Swiss/light) ─────────────────────────────────────────────────

rodColor :: String
rodColor = "#1c1c1c"

pivotColor :: String
pivotColor = "#1c1c1c"

bob1Color :: String
bob1Color = "#1e5a8c"

bob2Color :: String
bob2Color = "#c41e3a"

-- ── Component ────────────────────────────────────────────────────────────────

type State =
  { frames :: Array (Array Number)
  , idx :: Int
  , trail :: Array (Tuple Number Number)
  }

data Action = Initialize | Tick

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: \_ -> { frames: [], idx: 0, trail: [] }
    , render
    , eval: H.mkEval H.defaultEval
        { initialize = Just Initialize
        , handleAction = handleAction
        }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render _ = HH.div [ HP.id "dp-host" ] []

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    traj <- H.liftAff (loadTrajectory "double-pendulum.json")
    H.modify_ _ { frames = traj.frames }
    liftEffect renderShell
    handleAction Tick
  Tick -> do
    st <- H.get
    let n = Array.length st.frames
    when (n > 0) do
      let
        wrapped = st.idx >= n
        idx = if wrapped then 0 else st.idx
        frame = fromMaybe [ 0.0, 0.0, 0.0, 0.0 ] (Array.index st.frames idx)
        bob2 = Tuple (at frame 2) (at frame 3)
        baseTrail = if wrapped then [] else st.trail
        trail = capTrail (Array.snoc baseTrail bob2)
      H.modify_ _ { idx = idx + 1, trail = trail }
      liftEffect (renderScene frame trail)
    H.liftAff (delay (Milliseconds 16.0))
    handleAction Tick

at :: Array Number -> Int -> Number
at arr i = fromMaybe 0.0 (Array.index arr i)

capTrail :: Array (Tuple Number Number) -> Array (Tuple Number Number)
capTrail ts = Array.drop (max 0 (Array.length ts - trailLen)) ts

-- ── Rendering (HATS) ─────────────────────────────────────────────────────────

-- The SVG shell, rendered once; the animated content lives in `#dp-scene`.
renderShell :: Effect Unit
renderShell = void $ IT.rerender "#dp-host" shell
  where
  shell :: HATS.Tree
  shell =
    HATS.elem SVG
      [ F.attr "id" "dp-svg"
      , F.class_ "dp-svg"
      , F.width 720.0
      , F.height 720.0
      , F.viewBox (-360.0) (-360.0) 720.0 720.0
      , F.attr "preserveAspectRatio" "xMidYMid meet"
      ]
      [ HATS.elem Group [ F.attr "id" "dp-scene" ] [] ]

renderScene :: Array Number -> Array (Tuple Number Number) -> Effect Unit
renderScene frame trail = void $ IT.rerender "#dp-scene" scene
  where
  Tuple c0x c0y = toCanvas 0.0 0.0
  Tuple c1x c1y = toCanvas (at frame 0) (at frame 1)
  Tuple c2x c2y = toCanvas (at frame 2) (at frame 3)

  scene :: HATS.Tree
  scene =
    trailEl
      <> rod c0x c0y c1x c1y
      <> rod c1x c1y c2x c2y
      <> bob c0x c0y 5.0 pivotColor
      <> bob c1x c1y 11.0 bob1Color
      <> bob c2x c2y 11.0 bob2Color

  trailEl =
    HATS.elem Path
      [ F.d (trailD trail)
      , F.fill "none"
      , F.stroke bob2Color
      , F.strokeWidth 1.4
      , F.opacity "0.55"
      ]
      []

  rod ax ay bx by =
    HATS.elem Line
      [ F.x1 ax, F.y1 ay, F.x2 bx, F.y2 by, F.stroke rodColor, F.strokeWidth 3.0 ]
      []

  bob bx by rr col =
    HATS.elem Circle
      [ F.cx bx, F.cy by, F.r rr, F.fill col, F.stroke "#ffffff", F.strokeWidth 2.0 ]
      []

-- An SVG path "M x y L x y …" through the trail points (in canvas coords).
trailD :: Array (Tuple Number Number) -> String
trailD pts = case Array.uncons pts of
  Nothing -> ""
  Just { head, tail } -> "M " <> seg head <> foldMap (\p -> " L " <> seg p) tail
  where
  seg (Tuple x y) =
    let Tuple cx cy = toCanvas x y in show cx <> " " <> show cy
