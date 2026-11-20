-- | A straight-line program: `NumExpr` trees flattened into numbered
-- | instructions, each computed once.
-- |
-- | A `NumExpr` is a tree, and a tree cannot say "this value, again". An
-- | integrator needs to say exactly that: the fourth stage of RK4 uses the
-- | third, which uses the second, and written as trees the expressions grow
-- | by a factor of their own size at every stage. A `Program` is the same
-- | arithmetic with the sharing written down. Every instruction writes one
-- | slot; an operand is a constant or an earlier slot.
-- |
-- | It is a description, so it has more than one denotation. `run` is the
-- | pure one, here, on any backend. `Data.Simulation.Julia` hands the same
-- | instructions to Julia, which compiles them to native code. Both perform
-- | the same IEEE operations on the same operands in the same order, which
-- | is what lets one be checked against the other to the last bit.
-- |
-- | Two instructions that apply the same operation to the same operands are
-- | merged when the program is built. Nothing is reassociated, folded or
-- | simplified: `a + b` and `b + a` stay two instructions.
module Data.NumExpr.Program
  ( Program
  , Operand(..)
  , Instruction(..)
  , BinaryOp(..)
  , Scope
  , Build
  , Building
  , build
  , lower
  , emit
  , scopeOf
  , inputCount
  , instructions
  , outputs
  , run
  ) where

import Prelude

import Control.Monad.ST (ST)
import Control.Monad.State (StateT, evalStateT, get, put)
import Control.Monad.Trans.Class (lift)
import Data.Array (length, mapWithIndex, replicate)
import Data.Array as Array
import Data.Array.ST (STArray)
import Data.Array.ST as STArray
import Data.Array.ST.Partial as STPartial
import Data.Either (Either(..))
import Data.FoldableWithIndex (traverseWithIndex_)
import Data.List (List(..))
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.NumExpr (NumExpr(..), UnaryFn, applyFn, fnName, power)
import Data.Tuple (Tuple(..))
import Partial.Unsafe (unsafePartial)

data BinaryOp = Plus | Minus | Times | Over | Power

-- | A constant, or the value an earlier instruction (or an input) left in
-- | a slot. Inputs occupy slots `0 .. inputCount - 1`; instruction `i`
-- | writes slot `inputCount + i`.
data Operand = Constant Number | Slot Int

data Instruction
  = Binary BinaryOp Operand Operand
  | Negate Operand
  | Apply UnaryFn Operand

newtype Program = Program
  { inputs :: Int
  , instructions :: Array Instruction
  , outputs :: Array Operand
  }

inputCount :: Program -> Int
inputCount (Program p) = p.inputs

instructions :: Program -> Array Instruction
instructions (Program p) = p.instructions

outputs :: Program -> Array Operand
outputs (Program p) = p.outputs

-- | What a variable name means while a program is being built: an input,
-- | or a value computed earlier in the same program.
type Scope = Map String Operand

-- | The program so far: the instructions emitted, and which values they
-- | already hold.
type Building =
  { known :: Map String Operand
  , reversed :: List Instruction
  , next :: Int
  }

-- | Building a program can fail (an expression names a variable nothing
-- | binds), and it threads the instructions emitted so far.
type Build = StateT Building (Either String)

-- | Build a program over the named inputs. The body receives the scope that
-- | binds each input name to its slot and returns the operands to output.
build :: Array String -> (Scope -> Build (Array Operand)) -> Either String Program
build names body = do
  outs <- evalAndCollect
  pure (Program { inputs: count, instructions: outs.code, outputs: outs.operands })
  where
  count = length names
  inputScope = scopeOf (mapWithIndex (\i name -> Tuple name (Slot i)) names)
  evalAndCollect = evalStateT collect { known: Map.empty, reversed: Nil, next: count }
  collect = do
    operands <- body inputScope
    final <- get
    pure { operands, code: Array.fromFoldable (List.reverse final.reversed) }

scopeOf :: Array (Tuple String Operand) -> Scope
scopeOf = Map.fromFoldable

-- | Flatten one expression into the program under construction and return
-- | the operand holding its value.
lower :: Scope -> NumExpr -> Build Operand
lower scope = go
  where
  go = case _ of
    Lit n -> pure (Constant n)
    Var name -> case Map.lookup name scope of
      Just operand -> pure operand
      Nothing -> lift (Left ("the expression names `" <> name <> "`, which nothing binds"))
    Add a b -> binary Plus a b
    Sub a b -> binary Minus a b
    Mul a b -> binary Times a b
    Div a b -> binary Over a b
    Pow a b -> binary Power a b
    Neg a -> go a >>= Negate >>> emit
    Ap f a -> go a >>= Apply f >>> emit
  binary op a b = do
    x <- go a
    y <- go b
    emit (Binary op x y)

emit :: Instruction -> Build Operand
emit instruction = do
  building <- get
  case Map.lookup key building.known of
    Just operand -> pure operand
    Nothing -> do
      let slot = Slot building.next
      put
        { known: Map.insert key slot building.known
        , reversed: Cons instruction building.reversed
        , next: building.next + 1
        }
      pure slot
  where
  key = instructionKey instruction

-- The key two instructions share exactly when they compute the same value.
-- Constants are keyed by `show`, which tells 0.0 from -0.0 where `==` on
-- Number does not; merging `x * 0.0` with `x * -0.0` would change a sign.
instructionKey :: Instruction -> String
instructionKey = case _ of
  Binary op a b -> opName op <> " " <> operandKey a <> " " <> operandKey b
  Negate a -> "neg " <> operandKey a
  Apply f a -> fnName f <> " " <> operandKey a

operandKey :: Operand -> String
operandKey = case _ of
  Constant n -> "c" <> show n
  Slot i -> "s" <> show i

opName :: BinaryOp -> String
opName = case _ of
  Plus -> "+"
  Minus -> "-"
  Times -> "*"
  Over -> "/"
  Power -> "^"

-- | The pure denotation: run the instructions in order over the inputs.
-- | `inputs` must have `inputCount` elements; a shorter array is a bug in
-- | the caller, which the simulations in `Data.Simulation` never make.
run :: Program -> Array Number -> Array Number
run (Program p) inputs = map (operandIn slots) p.outputs
  where
  slots = STArray.run do
    cells <- STArray.thaw (inputs <> replicate (length p.instructions) 0.0)
    traverseWithIndex_ (\i instruction -> step cells (p.inputs + i) instruction) p.instructions
    pure cells

  step :: forall h. STArray h Number -> Int -> Instruction -> ST h Unit
  step cells target instruction = do
    value <- case instruction of
      Binary op a b -> apply2 op <$> read cells a <*> read cells b
      Negate a -> negate <$> read cells a
      Apply f a -> applyFn f <$> read cells a
    unsafePartial (STPartial.poke target value cells)

  read :: forall h. STArray h Number -> Operand -> ST h Number
  read cells = case _ of
    Constant n -> pure n
    Slot i -> unsafePartial (STPartial.peek i cells)

  operandIn :: Array Number -> Operand -> Number
  operandIn values = case _ of
    Constant n -> n
    Slot i -> unsafePartial (Array.unsafeIndex values i)

apply2 :: BinaryOp -> Number -> Number -> Number
apply2 = case _ of
  Plus -> (+)
  Minus -> (-)
  Times -> (*)
  Over -> (/)
  Power -> power
