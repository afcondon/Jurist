-- | A simulation as a description: a system of ODEs, how to start it, how
-- | far to run it, and the conditions that end it early.
-- |
-- | The integrator is written here, once, in PureScript, and it is written
-- | over expressions and not over numbers. `simulation` takes the rates of
-- | change as `NumExpr`s and builds the whole Runge-Kutta step as a
-- | `Program`: four evaluations of the rates, each at a state computed
-- | from the last, and the weighted sum. That program is data. `simulate`
-- | interprets it here, on any backend, and `Data.Simulation.Julia` hands
-- | the same instructions to Julia to compile. Neither side holds a second
-- | copy of the method, so there is nothing to keep in step by hand, and
-- | the two agree to the last bit because they perform the same operations.
-- |
-- | What the run means, for every denotation:
-- |
-- |   1. The start program computes the time step, the horizon, the initial
-- |      state and the constants from the inputs.
-- |   2. While the time is below the horizon: take one step, add the time
-- |      step to the time, then evaluate the events at the new state, in
-- |      the order they were given. The first event whose value is above
-- |      zero ends the run, with the state as the step left it.
-- |   3. If no event fired, apply the updates, in the order they were
-- |      given: each one whose `every` divides the number of steps taken.
-- |
-- | A state variable is either integrated (it has a rate) or held (it keeps
-- | its value until an update sets it). Held variables and updates are how a
-- | run does something that is not a differential equation: count, remember
-- | a maximum, rescale a vector that has grown too long, switch a controller.
-- |
-- | The system is autonomous: a rate may name inputs, derived constants and
-- | state variables, and not the time.
module Data.Simulation
  ( Spec
  , Variable
  , Held
  , Update
  , Simulation
  , Outcome
  , Frame
  , simulation
  , simulate
  , trajectory
  , inputNames
  , stateNames
  , constantNames
  , eventNames
  , startProgram
  , stepProgram
  , updatePrograms
  ) where

import Prelude

import Data.Array (drop, elem, find, findIndex, foldl, length, take, zip)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldM, for_)
import Data.List (List(..))
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.NumExpr (NumExpr(..))
import Data.NumExpr.Program (BinaryOp(..), Build, Instruction(..), Operand(..), Program, Scope, build, emit, lower, run)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)

-- | One integrated state variable: where it starts and how fast it changes.
type Variable = { name :: String, initial :: NumExpr, rate :: NumExpr }

-- | One held state variable: where it starts. Only an update changes it.
type Held = { name :: String, initial :: NumExpr }

-- | New values for some state variables, applied after every `every`th
-- | step. All of `set` is computed from the state before the update, so
-- | the order within one update does not matter.
type Update = { every :: Int, set :: Array (Tuple String NumExpr) }

-- | - `inputs`: the numbers a run is given, constant while it runs (the
-- |   parameters, and whatever a sweep varies).
-- | - `derived`: constants computed once from the inputs, in order; each
-- |   may name the inputs and the ones before it.
-- | - `state`: the integrated variables. An `initial` may name inputs and
-- |   derived constants; a `rate` may also name the state, held included.
-- | - `held`: the variables only an update changes.
-- | - `timeStep`, `horizon`: over inputs and derived constants.
-- | - `events`: named conditions over inputs, derived constants and state.
-- |   An event fires when its expression is above zero.
-- | - `updates`: over inputs, derived constants and state; each sets
-- |   integrated or held variables.
type Spec =
  { inputs :: Array String
  , derived :: Array (Tuple String NumExpr)
  , state :: Array Variable
  , held :: Array Held
  , updates :: Array Update
  , timeStep :: NumExpr
  , horizon :: NumExpr
  , events :: Array (Tuple String NumExpr)
  }

newtype Simulation = Simulation
  { inputs :: Array String
  , state :: Array String
  , constants :: Array String
  , events :: Array String
  -- inputs -> [time step, horizon] <> initial state <> constants
  , start :: Program
  -- state <> constants <> [time step] -> next state <> event values
  , step :: Program
  -- each: state <> constants -> state
  , updates :: Array { every :: Int, program :: Program }
  }

inputNames :: Simulation -> Array String
inputNames (Simulation s) = s.inputs

stateNames :: Simulation -> Array String
stateNames (Simulation s) = s.state

constantNames :: Simulation -> Array String
constantNames (Simulation s) = s.constants

eventNames :: Simulation -> Array String
eventNames (Simulation s) = s.events

startProgram :: Simulation -> Program
startProgram (Simulation s) = s.start

stepProgram :: Simulation -> Program
stepProgram (Simulation s) = s.step

updatePrograms :: Simulation -> Array { every :: Int, program :: Program }
updatePrograms (Simulation s) = s.updates

-- | Build the simulation: the start program, and one classical fourth-order
-- | Runge-Kutta step with the events evaluated at its result, and one
-- | program for each update. Fails if an expression names something its
-- | position does not allow.
simulation :: Spec -> Either String Simulation
simulation spec = do
  for_ spec.updates \update -> do
    when (update.every < 1) (Left "an update's `every` must be at least 1")
    for_ update.set \(Tuple name _) ->
      unless (name `elem` stateNames') (Left ("an update sets `" <> name <> "`, which is not a state variable"))
  start <- build spec.inputs \inputs -> do
    scope <- foldM define inputs spec.derived
    dt <- lower scope spec.timeStep
    horizon <- lower scope spec.horizon
    integrated <- traverse (lower scope <<< _.initial) spec.state
    held <- traverse (lower scope <<< _.initial) spec.held
    let initial = integrated <> held
    constants <- traverse (lower scope <<< Var) constantNames'
    pure ([ dt, horizon ] <> initial <> constants)
  step <- build (stateNames' <> constantNames' <> [ timeStepName ]) \scope -> do
    let
      here = map (operandOf scope) integratedNames
      kept = map (operandOf scope) heldNames
      dt = operandOf scope timeStepName
      rates at = traverse (lower (rebind scope at) <<< _.rate) spec.state
    half <- emit (Binary Over dt (Constant 2.0))
    k1 <- rates here
    k2 <- rates =<< advance here half k1
    k3 <- rates =<< advance here half k2
    k4 <- rates =<< advance here dt k3
    sixth <- emit (Binary Over dt (Constant 6.0))
    next <- traverse (combine sixth) (zip here (zip (zip k1 k2) (zip k3 k4)))
    fired <- traverse (lower (rebind scope next) <<< snd) spec.events
    pure (next <> kept <> fired)
  updates <- traverse updateProgram spec.updates
  pure
    ( Simulation
        { inputs: spec.inputs
        , state: stateNames'
        , constants: constantNames'
        , events: map fst spec.events
        , start
        , step
        , updates
        }
    )
  where
  integratedNames = map _.name spec.state
  heldNames = map _.name spec.held
  stateNames' = integratedNames <> heldNames
  constantNames' = spec.inputs <> map fst spec.derived

  -- Every state variable, in order: its new value if the update sets it,
  -- otherwise the value it had.
  updateProgram :: Update -> Either String { every :: Int, program :: Program }
  updateProgram update = do
    program <- build (stateNames' <> constantNames') \scope ->
      traverse
        ( \name -> case find (fst >>> (_ == name)) update.set of
            Just (Tuple _ expr) -> lower scope expr
            Nothing -> pure (operandOf scope name)
        )
        stateNames'
    pure { every: update.every, program }

  define :: Scope -> Tuple String NumExpr -> Build Scope
  define scope (Tuple name expr) = do
    operand <- lower scope expr
    pure (Map.insert name operand scope)

  -- The scope with the integrated variables bound to the given operands.
  rebind :: Scope -> Array Operand -> Scope
  rebind scope operands = Map.union (Map.fromFoldable (zip integratedNames operands)) scope

  -- state + factor * slope, one variable at a time.
  advance :: Array Operand -> Operand -> Array Operand -> Build (Array Operand)
  advance here factor slopes = traverse shift (zip here slopes)
    where
    shift (Tuple s k) = do
      scaled <- emit (Binary Times factor k)
      emit (Binary Plus s scaled)

  -- s + (dt / 6) * (((k1 + 2 k2) + 2 k3) + k4), associated as written.
  combine :: Operand -> Tuple Operand (Tuple (Tuple Operand Operand) (Tuple Operand Operand)) -> Build Operand
  combine sixth (Tuple s (Tuple (Tuple k1 k2) (Tuple k3 k4))) = do
    twoK2 <- emit (Binary Times (Constant 2.0) k2)
    twoK3 <- emit (Binary Times (Constant 2.0) k3)
    sum12 <- emit (Binary Plus k1 twoK2)
    sum123 <- emit (Binary Plus sum12 twoK3)
    total <- emit (Binary Plus sum123 k4)
    weighted <- emit (Binary Times sixth total)
    emit (Binary Plus s weighted)

-- The step program's own name for the time step. A leading space keeps it
-- out of reach of any name a `Spec` can sensibly use.
timeStepName :: String
timeStepName = " time step"

-- A scope built by `build` binds every input name, and the step program's
-- inputs are exactly the names looked up here.
operandOf :: Scope -> String -> Operand
operandOf scope name = fromMaybe (Constant 0.0) (Map.lookup name scope)

-- | How a run ended. `event` is the index, in the order the `Spec` gave
-- | them, of the event that fired; `Nothing` means it reached the horizon.
type Outcome =
  { time :: Number
  , event :: Maybe Int
  , steps :: Int
  , state :: Array Number
  }

type Started =
  { dt :: Number
  , horizon :: Number
  , initial :: Array Number
  , constants :: Array Number
  }

begin :: Simulation -> Array Number -> Started
begin (Simulation s) inputs =
  { dt: fromMaybe 0.0 (Array.index out 0)
  , horizon: fromMaybe 0.0 (Array.index out 1)
  , initial: take states (drop 2 out)
  , constants: drop (2 + states) out
  }
  where
  out = run s.start inputs
  states = length s.state

type Stepped = { state :: Array Number, fired :: Maybe Int }

stepOnce :: Simulation -> Started -> Array Number -> Stepped
stepOnce (Simulation s) started state =
  { state: take states out
  , fired: findIndex (_ > 0.0) (drop states out)
  }
  where
  out = run s.step (state <> started.constants <> [ started.dt ])
  states = length s.state

-- The updates due after the given number of steps, applied in order.
settle :: Simulation -> Started -> Int -> Array Number -> Array Number
settle (Simulation s) started steps state = foldl apply state s.updates
  where
  apply current update =
    if steps `mod` update.every == 0 then run update.program (current <> started.constants)
    else current

-- | The pure denotation of a run: the inputs, in the order of `inputNames`,
-- | to how it ended.
simulate :: Simulation -> Array Number -> Outcome
simulate sim inputs = go 0.0 0 started.initial
  where
  started = begin sim inputs
  go time steps state =
    if time < started.horizon then
      let
        stepped = stepOnce sim started state
        time' = time + started.dt
      in
        case stepped.fired of
          Just event -> { time: time', event: Just event, steps: steps + 1, state: stepped.state }
          Nothing -> go time' (steps + 1) (settle sim started (steps + 1) stepped.state)
    else { time, event: Nothing, steps, state }

-- | The state at one moment of a run.
type Frame = { time :: Number, state :: Array Number }

-- | The same run, keeping the state as it goes: the start, every
-- | `stride`th step, and the last step whatever its number.
trajectory :: Simulation -> Int -> Array Number -> Array Frame
trajectory sim stride inputs =
  Array.fromFoldable (List.reverse (go 0.0 0 started.initial (Cons (frame 0.0 started.initial) Nil)))
  where
  started = begin sim inputs
  frame time state = { time, state }
  go time steps state frames =
    if time < started.horizon then
      let
        stepped = stepOnce sim started state
        time' = time + started.dt
        steps' = steps + 1
        settled = settle sim started steps' stepped.state
      in
        case stepped.fired of
          Just _ -> Cons (frame time' stepped.state) frames
          Nothing ->
            if steps' `mod` stride == 0 then go time' steps' settled (Cons (frame time' settled) frames)
            else go time' steps' settled frames
    else if steps `mod` stride == 0 then frames
    else Cons (frame time state) frames
