-- | Tier-2 (increment 1): a typed numeric-expression eDSL that stages across
-- | the seam *once* and is compiled to a native Julia function.
-- |
-- | `NumExpr` is a precision ADT (ADR-0001) — an expression is correct by
-- | construction before any interpretation runs on it. It carries a
-- | `Semiring`/`Ring` instance, so expressions are written with ordinary
-- | `+ * -`:
-- |
-- | ```purescript
-- | num 10.0 * (var "y" - var "x") + sinE (var "z")
-- | ```
-- |
-- | This is the real answer to the `mapNum` caveat: instead of a PureScript
-- | closure per evaluation crossing the seam (the callback anti-pattern), the
-- | whole expression crosses *once* as a description, and Julia metaprograms
-- | it into a native function (`docs/julia-shaped-libraries.md`, ADR-0007).
-- |
-- | Representation independence (ADR-0002): the Julia shim never destructures
-- | a PureScript `NumExpr`. `toJExpr` folds the AST on the PS side, calling
-- | Julia *builders* (`jAdd`, `jMul`, …) handed in as ordinary functions, so
-- | Julia assembles its own `Expr` — "constructors across, handles back".
module Data.NumExpr
  ( NumExpr(..)
  , UnaryFn(..)
  , var
  , num
  , divide
  , pow
  , sinE
  , cosE
  , expE
  , logE
  , sqrtE
  , eval
  , render
  , JExpr
  , toJExpr
  , Compiled
  , compile
  , evalBatch
  ) where

import Prelude

import Data.Number as Num
import Effect (Effect)

-- | The native unary functions the eDSL can stage.
data UnaryFn = Sin | Cos | Exp | Log | Sqrt

-- | A numeric expression over named variables.
data NumExpr
  = Lit Number
  | Var String
  | Add NumExpr NumExpr
  | Sub NumExpr NumExpr
  | Mul NumExpr NumExpr
  | Div NumExpr NumExpr
  | Neg NumExpr
  | Pow NumExpr NumExpr
  | Ap UnaryFn NumExpr

-- Ergonomic numeric syntax: `+`, `*`, and (via Ring) `-` build the AST.
instance semiringNumExpr :: Semiring NumExpr where
  add = Add
  mul = Mul
  zero = Lit 0.0
  one = Lit 1.0

instance ringNumExpr :: Ring NumExpr where
  sub = Sub

var :: String -> NumExpr
var = Var

num :: Number -> NumExpr
num = Lit

divide :: NumExpr -> NumExpr -> NumExpr
divide = Div

pow :: NumExpr -> NumExpr -> NumExpr
pow = Pow

sinE :: NumExpr -> NumExpr
sinE = Ap Sin

cosE :: NumExpr -> NumExpr
cosE = Ap Cos

expE :: NumExpr -> NumExpr
expE = Ap Exp

logE :: NumExpr -> NumExpr
logE = Ap Log

sqrtE :: NumExpr -> NumExpr
sqrtE = Ap Sqrt

-- | Reference interpreter — the structural semantics the staged, compiled
-- | function must reproduce.
eval :: (String -> Number) -> NumExpr -> Number
eval env = go
  where
  go = case _ of
    Lit n -> n
    Var s -> env s
    Add a b -> go a + go b
    Sub a b -> go a - go b
    Mul a b -> go a * go b
    Div a b -> go a / go b
    Neg a -> negate (go a)
    Pow a b -> Num.pow (go a) (go b)
    Ap f a -> applyFn f (go a)

applyFn :: UnaryFn -> Number -> Number
applyFn = case _ of
  Sin -> Num.sin
  Cos -> Num.cos
  Exp -> Num.exp
  Log -> Num.log
  Sqrt -> Num.sqrt

-- | Fully-parenthesised pretty-printer.
render :: NumExpr -> String
render expr = case expr of
  Lit n -> show n
  Var s -> s
  Add a b -> bin "+" a b
  Sub a b -> bin "-" a b
  Mul a b -> bin "*" a b
  Div a b -> bin "/" a b
  Neg a -> "(-" <> render a <> ")"
  Pow a b -> bin "^" a b
  Ap f a -> fnName f <> "(" <> render a <> ")"
  where
  bin op a b = "(" <> render a <> " " <> op <> " " <> render b <> ")"

fnName :: UnaryFn -> String
fnName = case _ of
  Sin -> "sin"
  Cos -> "cos"
  Exp -> "exp"
  Log -> "log"
  Sqrt -> "sqrt"

-- | An opaque handle to a Julia-built expression node (a Julia `Expr`).
foreign import data JExpr :: Type

foreign import jLit :: Number -> JExpr
foreign import jVar :: String -> JExpr
foreign import jAdd :: JExpr -> JExpr -> JExpr
foreign import jSub :: JExpr -> JExpr -> JExpr
foreign import jMul :: JExpr -> JExpr -> JExpr
foreign import jDiv :: JExpr -> JExpr -> JExpr
foreign import jNeg :: JExpr -> JExpr
foreign import jPow :: JExpr -> JExpr -> JExpr
foreign import jApp :: String -> JExpr -> JExpr

-- | Replay the PS AST through the Julia builders — the single seam crossing.
toJExpr :: NumExpr -> JExpr
toJExpr = case _ of
  Lit n -> jLit n
  Var s -> jVar s
  Add a b -> jAdd (toJExpr a) (toJExpr b)
  Sub a b -> jSub (toJExpr a) (toJExpr b)
  Mul a b -> jMul (toJExpr a) (toJExpr b)
  Div a b -> jDiv (toJExpr a) (toJExpr b)
  Neg a -> jNeg (toJExpr a)
  Pow a b -> jPow (toJExpr a) (toJExpr b)
  Ap f a -> jApp (fnName f) (toJExpr a)

-- | An opaque handle to a native Julia function compiled from a `JExpr`.
foreign import data Compiled :: Type

-- | Compile a Julia-assembled expression over an ordered variable list into a
-- | native function (Julia metaprogramming: `eval` of a generated lambda).
foreign import compileJ :: Array String -> JExpr -> Effect Compiled

-- | Evaluate the compiled function over a batch of variable-assignment rows.
foreign import evalBatch :: Compiled -> Array (Array Number) -> Effect (Array Number)

-- | Stage a `NumExpr` to a native Julia function: fold to `JExpr`, then compile.
compile :: Array String -> NumExpr -> Effect Compiled
compile vars e = compileJ vars (toJExpr e)
