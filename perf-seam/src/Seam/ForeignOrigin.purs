-- | The population nothing else tests: values that ENTER from a foreign
-- | library.
-- |
-- | The differential corpus proves that meaning survives translation, but only
-- | for values **PureScript itself constructed** — it deliberately contains no
-- | foreign libraries, so every `Number` in it is the runtime's own canonical
-- | double. The canary compares a backend against itself and never crosses a
-- | seam at all. Between them they leave a hole exactly the shape of the thing
-- | the backends exist for, and a real bug lived in it:
-- |
-- | > `show (399.7569 :: Number)` printed `np.float64(3997569)` on Pythia,
-- | > silently, for any value that came back from numpy — because numpy 2.x
-- | > changed scalar `repr` and the runtime's digit-placement code parses
-- | > `repr`. Found 2026-08-02 by a checksum gate in this lane, not by a test.
-- |
-- | The seam lane is the right home for the fix's regression test, because it
-- | is the only place in the repo where a library hands values back. But the
-- | hazard does not need a heavyweight library to reproduce, and pinning it to
-- | one would make the test track scipy's release notes. What it needs is the
-- | *fiction* an FFI signature creates: `Number` promises an IEEE double, and
-- | the host has several things that ARE a double without BEING its canonical
-- | one. `asRepresentation` manufactures each of them directly.
-- |
-- | ## The invariant
-- |
-- | ```
-- | show x == show (widen x)      for every x, however x arrived
-- | ```
-- |
-- | `widen` is the coercion the runtime now performs at the boundary. The
-- | property says the rendering of a `Number` may depend on its VALUE and must
-- | not depend on its REPRESENTATION. Note it is deliberately not
-- | `show (asRepresentation r v) == show v`: `Float32(0.1)` really is a
-- | different number from `0.1`, and printing `0.1` for it would be the
-- | opposite error.
module Seam.ForeignOrigin (main) where

import Prelude

import Data.Array (length)
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref

-- | Names of the host representations under test, supplied by the FFI because
-- | they differ per runtime — `Float32`/`Rational`/`BigFloat` on Julia,
-- | `numpy.float64`/`numpy.float32`/`Decimal` on Python. The shared source
-- | makes no claim about what they are, exactly as `Seam.Kernel` makes no
-- | claim about which library it calls.
foreign import representations :: Array String

-- | Re-express a double in one of the host's alternative representations, and
-- | hand it back typed as `Number`.
-- |
-- | The lie is the point. Every FFI signature in every polyglot program makes
-- | this same promise on the library's behalf, and the library keeps it only
-- | as far as its own type system cares to.
foreign import asRepresentation :: String -> Number -> Number

-- | Coerce to the runtime's canonical double — `Float64` on Julia, `float` on
-- | Python. Semantics-preserving by definition: a PureScript `Number` IS an
-- | IEEE double, so this names the value the type already claimed.
foreign import widen :: Number -> Number

foreign import exitWith :: Int -> Effect Unit

-- | Values chosen because each one broke something. 399.7569 and 1.0 are the
-- | two the numpy bug was first seen on; 0.1 is the classic Float32 witness
-- | (0.10000000149011612 as a double); 0.016 has a leading zero the mantissa
-- | parser mishandled; 1.0e21 and 1.0e-7 sit on the two boundaries where JS
-- | switches to exponential notation, which is where a representation slip is
-- | most likely to change the branch taken.
probes :: Array Number
probes = [ 399.7569, 1.0, 0.1, 0.016, 0.5, -2.5, 1.0e21, 1.0e-7 ]

main :: Effect Unit
main = do
  log "Seam.ForeignOrigin — show must not depend on how the value arrived"
  log ""
  failures <- Ref.new 0

  for_ representations \rep -> do
    log ("  " <> rep)
    for_ probes \v -> do
      let arrived = asRepresentation rep v
          got = show arrived
          want = show (widen arrived)
      if got == want then log ("    ok    " <> show v <> " -> " <> got)
      else do
        _ <- Ref.modify (_ + 1) failures
        log ("    FAIL  " <> show v <> " -> " <> got <> "  (want " <> want <> ")")
    log ""

  n <- Ref.read failures
  let total = length representations * length probes
  if n == 0 then do
    log ("PASS  " <> show total <> " renderings, "
         <> show (length representations) <> " representations")
    exitWith 0
  else do
    log ("FAIL  " <> show n <> " of " <> show total <> " renderings depend on"
         <> " the representation, not the value")
    exitWith 1
