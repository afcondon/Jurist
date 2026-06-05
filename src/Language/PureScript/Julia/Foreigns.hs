{-# LANGUAGE OverloadedStrings #-}

-- |
-- Built-in Julia FFI shims for the core libraries (prelude, effect,
-- console, and a few common extras). These cover what's needed to get
-- Prelude-using programs running; anything beyond is supplied by the
-- user via an @ffi-jl/@ directory (copied into the output last, so user
-- files win over these).
--
-- Conventions mirrored from the JS foreign modules:
--
--   * curried functions are chains of unary closures
--   * effects are zero-argument closures returning the result
--   * arrays are @Vector@s (built as @Any[...]@ by generated code)
--   * records are @Dict{String,Any}@
--   * @Ordering@-style results use the generated tag-tuples' string tags
--
module Language.PureScript.Julia.Foreigns
  ( builtinForeigns
  ) where

import Prelude
import Data.Text (Text)
import qualified Data.Text as T

-- | (output filename, file content)
builtinForeigns :: [(FilePath, Text)]
builtinForeigns =
  [ ( "Data_Unit_foreign.jl", T.unlines
      [ "# FFI for Data.Unit"
      , "unit = nothing"
      ] )
  , ( "Data_HeytingAlgebra_foreign.jl", T.unlines
      [ "# FFI for Data.HeytingAlgebra"
      , "boolConj(b1) = b2 -> b1 && b2"
      , "boolDisj(b1) = b2 -> b1 || b2"
      , "boolNot(b) = !b"
      ] )
  , ( "Data_Eq_foreign.jl", T.unlines
      [ "# FFI for Data.Eq"
      , "eqBooleanImpl(r1) = r2 -> r1 == r2"
      , "eqIntImpl(r1) = r2 -> r1 == r2"
      , "eqNumberImpl(r1) = r2 -> r1 == r2"
      , "eqCharImpl(r1) = r2 -> r1 == r2"
      , "eqStringImpl(r1) = r2 -> r1 == r2"
      , "eqArrayImpl(f) = xs -> ys ->"
      , "    Base.length(xs) == Base.length(ys) && Base.all(f(x)(y) for (x, y) in Base.zip(xs, ys))"
      ] )
  , ( "Data_Ord_foreign.jl", T.unlines
      [ "# FFI for Data.Ord"
      , "ordBooleanImpl(lt) = eq -> gt -> x -> y -> x < y ? lt : (x == y ? eq : gt)"
      , "ordIntImpl(lt) = eq -> gt -> x -> y -> x < y ? lt : (x == y ? eq : gt)"
      , "ordNumberImpl(lt) = eq -> gt -> x -> y -> x < y ? lt : (x == y ? eq : gt)"
      , "ordStringImpl(lt) = eq -> gt -> x -> y -> x < y ? lt : (x == y ? eq : gt)"
      , "ordCharImpl(lt) = eq -> gt -> x -> y -> x < y ? lt : (x == y ? eq : gt)"
      , "ordArrayImpl(f) = xs -> ys -> begin"
      , "    i = 1"
      , "    n = Base.min(Base.length(xs), Base.length(ys))"
      , "    while i <= n"
      , "        o = f(xs[i])(ys[i])"
      , "        if o != 0"
      , "            return o"
      , "        end"
      , "        i += 1"
      , "    end"
      , "    Base.cmp(Base.length(xs), Base.length(ys))"
      , "end"
      ] )
  , ( "Data_Show_foreign.jl", T.unlines
      [ "# FFI for Data.Show"
      , "showIntImpl(n) = Base.string(n)"
      , "showNumberImpl(n) = Base.string(n)"
      , "showCharImpl(c) = \"'\" * Base.string(c) * \"'\""
      , "showStringImpl(s) = Base.repr(s)"
      , "showArrayImpl(f) = xs -> \"[\" * Base.join(Any[f(x) for x in xs], \",\") * \"]\""
      , "cons(head) = tail -> Base.vcat(Any[head], tail)"
      , "join(separator) = xs -> Base.join(xs, separator)"
      ] )
  , ( "Data_Semiring_foreign.jl", T.unlines
      [ "# FFI for Data.Semiring"
      , "intAdd(x) = y -> x + y"
      , "intMul(x) = y -> x * y"
      , "numAdd(n1) = n2 -> n1 + n2"
      , "numMul(n1) = n2 -> n1 * n2"
      ] )
  , ( "Data_Ring_foreign.jl", T.unlines
      [ "# FFI for Data.Ring"
      , "intSub(x) = y -> x - y"
      , "numSub(n1) = n2 -> n1 - n2"
      ] )
  , ( "Data_EuclideanRing_foreign.jl", T.unlines
      [ "# FFI for Data.EuclideanRing"
      , "intDegree(x) = Base.min(Base.abs(x), 2147483647)"
      , "# Euclidean division/mod, matching the JS backend's semantics"
      , "intDiv(x) = y -> y == 0 ? 0 : Base.fld(x, y)"
      , "intMod(x) = y -> y == 0 ? 0 : Base.mod(x, Base.abs(y))"
      , "numDiv(n1) = n2 -> n1 / n2"
      ] )
  , ( "Data_Bounded_foreign.jl", T.unlines
      [ "# FFI for Data.Bounded"
      , "topInt = 2147483647"
      , "bottomInt = -2147483648"
      , "topChar = Base.Char(65535)"
      , "bottomChar = Base.Char(0)"
      , "topNumber = Base.Inf"
      , "bottomNumber = -Base.Inf"
      ] )
  , ( "Data_Semigroup_foreign.jl", T.unlines
      [ "# FFI for Data.Semigroup"
      , "concatString(s1) = s2 -> s1 * s2"
      , "concatArray(xs) = ys -> Base.vcat(xs, ys)"
      ] )
  , ( "Data_Functor_foreign.jl", T.unlines
      [ "# FFI for Data.Functor"
      , "arrayMap(f) = xs -> Any[f(x) for x in xs]"
      ] )
  , ( "Control_Bind_foreign.jl", T.unlines
      [ "# FFI for Control.Bind"
      , "arrayBind(arr) = f -> begin"
      , "    result = Any[]"
      , "    for x in arr"
      , "        Base.append!(result, f(x))"
      , "    end"
      , "    result"
      , "end"
      ] )
  , ( "Control_Apply_foreign.jl", T.unlines
      [ "# FFI for Control.Apply"
      , "arrayApply(fs) = xs -> Any[f(x) for f in fs for x in xs]"
      ] )
  , ( "Record_Unsafe_foreign.jl", T.unlines
      [ "# FFI for Record.Unsafe"
      , "unsafeGet(label) = rec -> rec[label]"
      , "unsafeSet(label) = value -> rec -> begin"
      , "    r = Base.copy(rec)"
      , "    r[label] = value"
      , "    r"
      , "end"
      , "unsafeDelete(label) = rec -> begin"
      , "    r = Base.copy(rec)"
      , "    Base.delete!(r, label)"
      , "    r"
      , "end"
      , "unsafeHas(label) = rec -> Base.haskey(rec, label)"
      ] )
  , ( "Data_Symbol_foreign.jl", T.unlines
      [ "# FFI for Data.Symbol"
      , "unsafeCoerce(x) = x"
      ] )
  , ( "Data_Reflectable_foreign.jl", T.unlines
      [ "# FFI for Data.Reflectable"
      , "unsafeCoerce(x) = x"
      ] )
  , ( "Data_Show_Generic_foreign.jl", T.unlines
      [ "# FFI for Data.Show.Generic"
      , "intercalate(separator) = xs -> Base.join(xs, separator)"
      ] )
  , ( "Data_Function_Uncurried_foreign.jl", T.unlines $
      [ "# FFI for Data.Function.Uncurried"
      , "mkFn0(fn) = () -> fn(nothing)"
      , "mkFn1(fn) = fn"
      ] ++
      [ "mkFn" <> T.pack (show n) <> "(fn) = (" <> argList n <> ") -> fn"
        <> T.concat ["(" <> arg i <> ")" | i <- [1..n]]
      | n <- [2..10 :: Int] ] ++
      [ "runFn0(fn) = fn()"
      , "runFn1(fn) = fn"
      ] ++
      [ "runFn" <> T.pack (show n) <> "(fn) = "
        <> T.concat [arg i <> " -> " | i <- [1..n]]
        <> "fn(" <> argList n <> ")"
      | n <- [2..10 :: Int] ] )
  , ( "Effect_foreign.jl", T.unlines
      [ "# FFI for Effect"
      , "pureE(a) = () -> a"
      , "bindE(a) = f -> () -> f(a())()"
      , "untilE(f) = () -> begin"
      , "    while !f(); end"
      , "    nothing"
      , "end"
      , "whileE(f) = a -> () -> begin"
      , "    while f()"
      , "        a()"
      , "    end"
      , "    nothing"
      , "end"
      , "forE(lo) = hi -> f -> () -> begin"
      , "    for i in lo:(hi - 1)"
      , "        f(i)()"
      , "    end"
      , "    nothing"
      , "end"
      , "foreachE(as) = f -> () -> begin"
      , "    for x in as"
      , "        f(x)()"
      , "    end"
      , "    nothing"
      , "end"
      ] )
  , ( "Effect_Console_foreign.jl", T.unlines
      [ "# FFI for Effect.Console"
      , "log(s) = () -> (Base.println(s); nothing)"
      , "warn(s) = () -> (Base.println(Base.stderr, s); nothing)"
      , "error(s) = () -> (Base.println(Base.stderr, s); nothing)"
      , "info(s) = () -> (Base.println(s); nothing)"
      , "debug(s) = () -> (Base.println(s); nothing)"
      , "time(label) = () -> nothing"
      , "timeLog(label) = () -> nothing"
      , "timeEnd(label) = () -> nothing"
      , "clear = () -> nothing"
      , "group(label) = () -> nothing"
      , "groupCollapsed(label) = () -> nothing"
      , "groupEnd = () -> nothing"
      ] )
  , ( "Effect_Unsafe_foreign.jl", T.unlines
      [ "# FFI for Effect.Unsafe"
      , "unsafePerformEffect(f) = f()"
      ] )
  , ( "Effect_Uncurried_foreign.jl", T.unlines $
      [ "# FFI for Effect.Uncurried"
      , "mkEffectFn1(fn) = (a) -> fn(a)()"
      ] ++
      [ "mkEffectFn" <> T.pack (show n) <> "(fn) = (" <> argList n <> ") -> fn"
        <> T.concat ["(" <> arg i <> ")" | i <- [1..n]] <> "()"
      | n <- [2..10 :: Int] ] ++
      [ "runEffectFn1(fn) = a -> () -> fn(a)"
      ] ++
      [ "runEffectFn" <> T.pack (show n) <> "(fn) = "
        <> T.concat [arg i <> " -> " | i <- [1..n]]
        <> "() -> fn(" <> argList n <> ")"
      | n <- [2..10 :: Int] ] )
  , ( "Effect_Ref_foreign.jl", T.unlines
      [ "# FFI for Effect.Ref"
      , "# A Ref is a one-element Any vector"
      , "_new(val) = () -> Any[val]"
      , "read(ref) = () -> ref[1]"
      , "modifyImpl(f) = ref -> () -> begin"
      , "    t = f(ref[1])"
      , "    ref[1] = t[\"state\"]"
      , "    t[\"value\"]"
      , "end"
      , "write(val) = ref -> () -> (ref[1] = val; nothing)"
      ] )
  , ( "Unsafe_Coerce_foreign.jl", T.unlines
      [ "# FFI for Unsafe.Coerce"
      , "unsafeCoerce(x) = x"
      ] )
  , ( "Partial_Unsafe_foreign.jl", T.unlines
      [ "# FFI for Partial.Unsafe"
      , "_unsafePartial(f) = f()"
      ] )
  , ( "Partial_foreign.jl", T.unlines
      [ "# FFI for Partial"
      , "_crashWith(msg) = Base.error(msg)"
      ] )
  ]
  where
    arg :: Int -> Text
    arg i = "a" <> T.pack (show i)
    argList :: Int -> Text
    argList n = T.intercalate ", " [arg i | i <- [1..n]]
