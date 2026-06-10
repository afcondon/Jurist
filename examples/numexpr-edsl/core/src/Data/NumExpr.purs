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
-- | This module is **backend-agnostic** — it holds no `foreign import`s, so it
-- | compiles on any PureScript backend (JS/Node, the BEAM, purejl). The Julia
-- | *denotation* of a `NumExpr` (the `JExpr` builders, `compile`, `evalBatch`)
-- | lives in the companion `Data.NumExpr.Julia`, which folds the AST exported
-- | here through Julia builders — "constructors across, handles back"
-- | (ADR-0002), the shim never destructuring a PureScript `NumExpr`.
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
  , fnName
  ) where

import Prelude

-- The reference interpreter's transcendental primitives. These are the *only*
-- foreign imports in `core` — the irreducible machine math (every backend has
-- them, under a different name), shimmed one line per backend: `NumExpr.js`
-- (Math.*), `NumExpr.erl` (math:* — purerl strands these in the deprecated
-- `Math` package, not `Data.Number`, so we can't just import them), and the
-- purejl `ffi-jl/Data_NumExpr_foreign.jl` (Base.*). Everything else in core is
-- pure PureScript, so the description and `integratePure` stay backend-agnostic.
foreign import numPow :: Number -> Number -> Number
foreign import numSin :: Number -> Number
foreign import numCos :: Number -> Number
foreign import numExp :: Number -> Number
foreign import numLog :: Number -> Number
foreign import numSqrt :: Number -> Number

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
    Pow a b -> numPow (go a) (go b)
    Ap f a -> applyFn f (go a)

applyFn :: UnaryFn -> Number -> Number
applyFn = case _ of
  Sin -> numSin
  Cos -> numCos
  Exp -> numExp
  Log -> numLog
  Sqrt -> numSqrt

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

-- | The name each unary function carries on both sides of the seam — the
-- | `render` pretty-printer and the Julia denotation (`Data.NumExpr.Julia`,
-- | which splices `fnName f` into the generated Julia lambda) agree on it.
fnName :: UnaryFn -> String
fnName = case _ of
  Sin -> "sin"
  Cos -> "cos"
  Exp -> "exp"
  Log -> "log"
  Sqrt -> "sqrt"
