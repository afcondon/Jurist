-- | The **Julia denotation** of the backend-agnostic `Data.NumExpr` eDSL.
-- |
-- | `Data.NumExpr` (in the `core` package) is the pure description — the ADT,
-- | the reference `eval`, and `render` — with no `foreign import`s, so it
-- | compiles on every backend. This module is the Julia-only companion: it
-- | folds that ADT through Julia *builders* (`jAdd`, `jMul`, …) handed across
-- | the seam, so Julia assembles its own `Expr` and the shim never destructures
-- | a PureScript `NumExpr` (ADR-0002: "constructors across, handles back").
-- | The assembled `JExpr` is then compiled to a native, specializing
-- | `RuntimeGeneratedFunction` (ADR-0007) and evaluated in batch.
-- |
-- | It lives in the `julia/` workspace (purejl backend) only; the `node/` and
-- | future BEAM workspaces depend on `core` and never see it.
module Data.NumExpr.Julia
  ( JExpr
  , toJExpr
  , Compiled
  , compile
  , evalBatch
  ) where

import Data.NumExpr (NumExpr(..), fnName)
import Effect (Effect)

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
-- | native function (Julia metaprogramming: a generated `RuntimeGeneratedFunction`).
foreign import compileJ :: Array String -> JExpr -> Effect Compiled

-- | Evaluate the compiled function over a batch of variable-assignment rows.
foreign import evalBatch :: Compiled -> Array (Array Number) -> Effect (Array Number)

-- | Stage a `NumExpr` to a native Julia function: fold to `JExpr`, then compile.
compile :: Array String -> NumExpr -> Effect Compiled
compile vars e = compileJ vars (toJExpr e)
