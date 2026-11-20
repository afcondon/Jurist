-- | The Julia denotation of `Data.Simulation`: the same two programs, handed
-- | across as Julia expressions and compiled to one native function.
-- |
-- | Nothing about the method lives on the Julia side. The Runge-Kutta step,
-- | the initial conditions and the events arrive as the instructions that
-- | `Data.Simulation.simulation` built, replayed through the `JExpr`
-- | builders (ADR-0002: constructors across, handles back). The shim wraps
-- | them in the loop that `Data.Simulation` documents and asks
-- | RuntimeGeneratedFunctions for a function. What Julia adds is what only
-- | Julia has here: native code for the loop, and real threads for `sweep`.
-- |
-- | `simulate` here and `Data.Simulation.simulate` must return the same
-- | outcome for the same inputs, bit for bit. `examples/staged-integrator`
-- | checks that on every run of the demo lane.
module Data.Simulation.Julia
  ( Compiled
  , Sweep
  , compile
  , simulate
  , sweep
  , trajectory
  , source
  ) where

import Prelude

import Data.Array (length, mapWithIndex)
import Data.Maybe (Maybe(..))
import Data.NumExpr (fnName)
import Data.NumExpr.Julia (JExpr, jAdd, jApp, jDiv, jLit, jMul, jNeg, jPow, jSelect, jSub, jVar)
import Data.NumExpr.Program (BinaryOp(..), Instruction(..), Operand(..), Program, inputCount, instructions, outputs)
import Data.Simulation (Frame, Outcome, Simulation, constantNames, eventNames, inputNames, startProgram, stateNames, stepProgram, updatePrograms)
import Effect (Effect)

-- | A simulation compiled to native Julia code.
foreign import data Compiled :: Type

-- `name = expr`, as a Julia expression.
foreign import jAssign :: String -> JExpr -> JExpr

type Lowered =
  { inputs :: Int
  , states :: Int
  , constants :: Int
  , events :: Int
  , start :: Array JExpr
  , startOutputs :: Array JExpr
  , step :: Array JExpr
  , stepOutputs :: Array JExpr
  , updates :: Array { every :: Int, prefix :: String, body :: Array JExpr, outputs :: Array JExpr }
  }

foreign import compileJ :: Lowered -> Effect Compiled

type RawOutcome = { time :: Number, event :: Int, steps :: Int, state :: Array Number }

foreign import simulateJ :: Compiled -> Array Number -> Effect RawOutcome

foreign import sweepJ :: Compiled -> Array (Array Number) -> Effect Sweep

foreign import trajectoryJ :: Compiled -> Int -> Array Number -> Effect (Array Frame)

foreign import sourceJ :: Compiled -> String

-- The two programs use separate families of names, so that the step can
-- read what the start computed without either shadowing the other. Slot
-- `i` of the start program is `a<i>`, of the step program `b<i>`, and of
-- the `k`th update `u<k>_<i>`.
startPrefix :: String
startPrefix = "a"

stepPrefix :: String
stepPrefix = "b"

updatePrefix :: Int -> String
updatePrefix k = "u" <> show k <> "_"

operand :: String -> Operand -> JExpr
operand prefix = case _ of
  Constant n -> jLit n
  Slot i -> jVar (prefix <> show i)

statements :: String -> Program -> Array JExpr
statements prefix program = mapWithIndex assign (instructions program)
  where
  at = operand prefix
  assign i instruction =
    jAssign (prefix <> show (inputCount program + i)) case instruction of
      Binary Plus a b -> jAdd (at a) (at b)
      Binary Minus a b -> jSub (at a) (at b)
      Binary Times a b -> jMul (at a) (at b)
      Binary Over a b -> jDiv (at a) (at b)
      Binary Power a b -> jPow (at a) (at b)
      Negate a -> jNeg (at a)
      Apply f a -> jApp (fnName f) (at a)
      Select a b t f -> jSelect (at a) (at b) (at t) (at f)

-- | Compile a simulation, once. The result runs any number of inputs.
compile :: Simulation -> Effect Compiled
compile sim = compileJ
  { inputs: length (inputNames sim)
  , states: length (stateNames sim)
  , constants: length (constantNames sim)
  , events: length (eventNames sim)
  , start: statements startPrefix (startProgram sim)
  , startOutputs: map (operand startPrefix) (outputs (startProgram sim))
  , step: statements stepPrefix (stepProgram sim)
  , stepOutputs: map (operand stepPrefix) (outputs (stepProgram sim))
  , updates: mapWithIndex
      ( \k update ->
          { every: update.every
          , prefix: updatePrefix k
          , body: statements (updatePrefix k) update.program
          , outputs: map (operand (updatePrefix k)) (outputs update.program)
          }
      )
      (updatePrograms sim)
  }

-- | One run. Same inputs, same outcome as `Data.Simulation.simulate`.
simulate :: Compiled -> Array Number -> Effect Outcome
simulate compiled inputs = simulateJ compiled inputs <#> \raw ->
  { time: raw.time
  , event: if raw.event < 0 then Nothing else Just raw.event
  , steps: raw.steps
  , state: raw.state
  }

-- | How each run of a sweep ended, as columns: `events` holds the index of
-- | the event that fired, or -1 where the run reached its horizon, and
-- | `states` the state each run ended in.
type Sweep =
  { times :: Array Number
  , events :: Array Int
  , steps :: Array Int
  , states :: Array (Array Number)
  }

-- | Many runs, one per row of inputs, on every thread Julia was started
-- | with. The seam is crossed once for the whole batch.
sweep :: Compiled -> Array (Array Number) -> Effect Sweep
sweep = sweepJ

-- | One run, keeping frames. Same frames as `Data.Simulation.trajectory`.
trajectory :: Compiled -> Int -> Array Number -> Effect (Array Frame)
trajectory = trajectoryJ

-- | The Julia function the simulation became, as text, for reading.
source :: Compiled -> String
source = sourceJ
