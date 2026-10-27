{-# LANGUAGE OverloadedStrings #-}

-- |
-- CoreFn -> Julia code generation (direct text emission).
--
-- Julia is expression-oriented, which makes this translation pleasantly
-- direct compared to the Python backend it's cribbed from: @let@/@begin@
-- are expressions, ternaries chain, closures capture boxed locals (so
-- local recursion needs no thunk machinery), and IIFEs provide scoping
-- where statements are needed inside an expression.
--
-- Representation choices (v1):
--
--   * ADT values are @PSData("Just", 1, x, nothing, nothing, ())@ (one type),
--     indexed like the tag-tuples they replace: tag at [1], fields from [2].
--   * Newtype constructors are identity functions.
--   * Typeclass dictionaries are @Dict{String,Any}@ records keyed by
--     member name, so CoreFn's @Accessor@ works uniformly.
--   * Records are @Dict{String,Any}@; update is @merge@.
--   * Arrays are @Any[...]@ vectors.
--   * Effects are zero-argument closures (thunks).
--   * Functions are curried unary closures; application is @(f)(x)(y)@,
--     except a saturated call of a known-arity top-level function (below).
--
-- Saturated calls and the inliner (ADR-0010):
--
-- A top-level binding that is an n-deep lambda chain is also a Julia
-- method, @_ps_sat_f(a, b, c) = body@, and a call that supplies at least
-- n arguments calls it directly (across modules, @_psmod_M._ps_sat_f@).
-- The curried @f@ stays, as a thin wrapper, for first-class use. A method
-- is a const binding Julia can infer through, where a call of the global
-- @f@ is not. Then purs's JS inliner set: runFnN/mkFnN and their
-- Effect/ST forms, primitive ops through a known dictionary, saturated
-- constructors.
--
-- Tail-call optimization (the trampoline):
--
-- Julia does not guarantee TCO, so - mirroring what purs itself does for
-- JS in CoreImp.Optimizer.TCO - bindings whose self-references are ALL
-- fully-saturated tail calls are compiled to a dispatch loop:
--
-- > f = (function ();
-- >       function _tco_loop(x1, x2); ... end;   # (1, newargs) | (0, result)
-- >       (x1) -> (x2) -> (begin; _tco_r = (1, (x1, x2,));
-- >           while _tco_r[1] == 1; _tco_r = _tco_loop(_tco_r[2]...); end;
-- >           _tco_r[2]; end);
-- >     end)()
--
-- The function-call-per-iteration shape (rather than rebinding loop
-- variables in place) is deliberate, again following purs: closures
-- created in the loop body must capture per-iteration bindings, and a
-- mutated-in-place loop variable would be boxed and shared across
-- iterations. Applies to top-level Rec groups (self-recursion arrives as
-- singleton Rec) and let-bound Rec groups (the ubiquitous local @go@).
--
-- Known v1 limitations:
--
--   * Mutual recursion is not trampolined (matches the JS backend, where
--     MonadRec is the idiom for unbounded non-self recursion).
--   * A pattern binding can shadow a name used by a later alternative
--     evaluated inside the same binding IIFE (inherited from the Python
--     backend's structure; rare in practice).
--
module Language.PureScript.Julia.CodeGen
  ( generateModuleJl
  , Known
  , knownBindings
  ) where

import Prelude

import Data.List (partition)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Text.Read (readMaybe)

import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import Language.PureScript.PSString (PSString, decodeString)

import Language.PureScript.Julia.CodeGen.Common

-- | What the whole program knows about one top-level binding (ADR-0010).
data KnownDef
  = KnownFn Int            -- ^ a lambda chain this many parameters deep
  | KnownCtor CtorShape    -- ^ a constructor
  -- | A top-level name applied to top-level names, such as the
  -- @negate = Data.Ring.negate ringNumber@ that CoreFn floats out of every
  -- use of a dictionary method. purs's inliner looks through these (its
  -- "expander"), and so do we.
  | KnownAlias P.ModuleName P.Ident [CoreFn.Expr CoreFn.Ann]

data CtorShape
  = CtorNewtype            -- ^ erased: the constructor is the identity
  | CtorDict [P.Ident]     -- ^ a type-class dictionary: a Dict of its fields
  | CtorData T.Text Int    -- ^ a data constructor: tag and field count

-- | Every top-level binding whose shape is known, keyed by module.
type Known = Map (P.ModuleName, P.Ident) KnownDef

-- | The arity map: one fold over every module's declarations, so a call in
-- one module is saturated against a definition in another. Foreigns are
-- not declarations, so they never appear and stay curried.
knownBindings :: [CoreFn.Module CoreFn.Ann] -> Known
knownBindings mods = Map.fromList
  [ ((CoreFn.moduleName m, ident), k)
  | m <- mods
  , bind <- CoreFn.moduleDecls m
  , (ident, expr) <- case bind of
      CoreFn.NonRec _ i e -> [(i, e)]
      CoreFn.Rec bs -> [ (i, e) | ((_, i), e) <- bs ]
  , Just k <- [knownDef expr] ]
  where
    knownDef = \case
      CoreFn.Constructor ann _ (P.ProperName ctor) fields -> Just . KnownCtor $ case ann of
        (_, _, Just CoreFn.IsNewtype) -> CtorNewtype
        (_, _, Just CoreFn.IsTypeClassConstructor) -> CtorDict fields
        _ -> CtorData (escapeStringJl ctor) (length fields)
      expr@(CoreFn.App {})
        | (CoreFn.Var _ (P.Qualified (P.ByModuleName mn) i), args) <- spine expr
        , all isTopVar args -> Just (KnownAlias mn i args)
      expr -> case abss expr of
        0 -> Nothing
        n -> Just (KnownFn n)
    isTopVar = \case
      CoreFn.Var _ (P.Qualified (P.ByModuleName _) _) -> True
      _ -> False
    abss (CoreFn.Abs _ _ b) = 1 + abss b
    abss _ = 0 :: Int

-- | @f a1 .. an@ as @(f, [a1 .. an])@.
spine :: CoreFn.Expr CoreFn.Ann -> (CoreFn.Expr CoreFn.Ann, [CoreFn.Expr CoreFn.Ann])
spine = go []
  where
    go args (CoreFn.App _ fn arg) = go (arg : args) fn
    go args other = (other, args)

-- | The method behind saturated calls of the top-level binding @name@, in
-- the generated-name namespace (see 'genPrefix').
satName :: T.Text -> T.Text
satName name = genPrefix <> "sat_" <> name

-- | One inlined dictionary operation (ADR-0010).
data DictOp
  = OpBinary T.Text   -- ^ a Julia binary operator
  | OpUnary T.Text    -- ^ a Julia unary operator
  | OpValue T.Text    -- ^ a constant (@zero@, @top@, ...)

-- | purs's @inlineCommonOperators@ and @inlineCommonValues@, keyed by
-- (method module, method, dictionary module, dictionary). Each means what
-- the *_foreign.jl shim it bypasses means.
dictOps :: [((T.Text, T.Text, T.Text, T.Text), DictOp)]
dictOps =
  [ (("Data.Semiring", m, "Data.Semiring", d), op)
  | d <- ["semiringInt", "semiringNumber"]
  , (m, op) <- [("add", OpBinary "+"), ("mul", OpBinary "*")] ] ++
  [ (("Data.Semiring", "zero", "Data.Semiring", "semiringInt"), OpValue "0")
  , (("Data.Semiring", "one", "Data.Semiring", "semiringInt"), OpValue "1")
  , (("Data.Semiring", "zero", "Data.Semiring", "semiringNumber"), OpValue "0.0")
  , (("Data.Semiring", "one", "Data.Semiring", "semiringNumber"), OpValue "1.0")
  , (("Data.Ring", "sub", "Data.Ring", "ringInt"), OpBinary "-")
  , (("Data.Ring", "sub", "Data.Ring", "ringNumber"), OpBinary "-")
  , (("Data.Ring", "negate", "Data.Ring", "ringInt"), OpUnary "-")
  , (("Data.Ring", "negate", "Data.Ring", "ringNumber"), OpUnary "-")
  , (("Data.EuclideanRing", "div", "Data.EuclideanRing", "euclideanRingNumber"), OpBinary "/")
  , (("Data.Semigroup", "append", "Data.Semigroup", "semigroupString"), OpBinary "*")
  , (("Data.HeytingAlgebra", "conj", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpBinary "&&")
  , (("Data.HeytingAlgebra", "disj", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpBinary "||")
  , (("Data.HeytingAlgebra", "not", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpUnary "!")
  , (("Data.Bounded", "top", "Data.Bounded", "boundedBoolean"), OpValue "true")
  , (("Data.Bounded", "bottom", "Data.Bounded", "boundedBoolean"), OpValue "false")
  ] ++
  [ (("Data.Eq", m, "Data.Eq", d), OpBinary o)
  | d <- ["eqInt", "eqNumber", "eqString", "eqChar", "eqBoolean"]
  , (m, o) <- [("eq", "=="), ("notEq", "!=")] ] ++
  [ (("Data.Ord", m, "Data.Ord", d), OpBinary o)
  | d <- ["ordInt", "ordNumber", "ordString", "ordChar", "ordBoolean"]
  , (m, o) <- [("lessThan", "<"), ("lessThanOrEq", "<="), ("greaterThan", ">"), ("greaterThanOrEq", ">=")] ]

-- | Generate the Julia body (declarations only, no module header) for a module
generateModuleJl :: Known -> CoreFn.Module CoreFn.Ann -> T.Text
generateModuleJl known cfModule = T.unlines $ map (generateBinding []) (CoreFn.moduleDecls cfModule)
  where
    currentModule :: P.ModuleName
    currentModule = CoreFn.moduleName cfModule

    currentModuleText :: T.Text
    currentModuleText = case currentModule of
      P.ModuleName mn -> mn

    -- | Generate a top-level binding, tracking names in the current Rec group
    generateBinding :: [T.Text] -> CoreFn.Bind CoreFn.Ann -> T.Text
    generateBinding _ (CoreFn.NonRec _ ident expr)
      | Just (KnownFn _) <- Map.lookup (currentModule, ident) known =
          satBinding [] ident expr
      | otherwise = identName ident <> " = " <> generateExpr [] expr
    generateBinding _ (CoreFn.Rec bindings) =
      -- Rec handling, in order of preference per binding:
      --   1. TCO: all self-refs are saturated tail calls -> dispatch loop,
      --      plain assignment, no thunk (other-member refs resolve at call
      --      time, or through _lazy_X() for thunked members).
      --   2. A function (a lambda chain) is a Julia method plus its curried
      --      wrapper (ADR-0010). A method body resolves globals when it is
      --      called, so it needs no thunk however the group refers to it.
      --   3. Smart thunk partition: only VALUE bindings that reference
      --      group members go through the lazy-thunk runtime.
      let tcoAnnotated = [ (b, tryTco (identName ident) expr)
                         | b@((_, ident), expr) <- bindings ]
          tcoBindings = [ (ident, ps, body)
                        | (((_, ident), _), Just (ps, body)) <- tcoAnnotated ]
          isFunction (_, expr) = case expr of
            CoreFn.Abs {} -> True
            _ -> False
          (functions, plainBindings) =
            partition isFunction [ b | (b, Nothing) <- tcoAnnotated ]
          allNames = Set.fromList [identName ident | ((_, ident), _) <- bindings]
          needsThunk ((_, _ident), expr) =
            not $ Set.null $ Set.intersection (collectLocalRefs currentModule expr) allNames
          (recursive, nonRecursive) = partition needsThunk plainBindings
          recNames = [identName ident | ((_, ident), _) <- recursive]
          tcoDefs = [ satTco recNames ident ps body | (ident, ps, body) <- tcoBindings ]
                    ++ [ satBinding recNames ident expr | ((_, ident), expr) <- functions ]
          nonRecDefs = [ identName ident <> " = " <> generateExpr [] expr
                       | ((_, ident), expr) <- nonRecursive
                       ]
          lazyDefs = [ "_lazy_" <> identName ident
                       <> " = _runtime_lazy(\"" <> identName ident <> "\", \""
                       <> escapeStringJl currentModuleText <> "\", () -> "
                       <> generateExpr recNames expr <> ")"
                     | ((_, ident), expr) <- recursive
                     ]
          valueDefs = [ identName ident <> " = _lazy_" <> identName ident <> "()"
                      | ((_, ident), _) <- recursive
                      ]
      in T.unlines (tcoDefs ++ nonRecDefs ++ lazyDefs ++ valueDefs)

    identName :: P.Ident -> T.Text
    identName = identToJlName

    -- | A known-arity function (ADR-0010): the method saturated calls reach,
    -- then the curried binding as a thin wrapper over it.
    satBinding :: [T.Text] -> P.Ident -> CoreFn.Expr CoreFn.Ann -> T.Text
    satBinding recNames ident expr =
      let (params, body) = peelAbs expr
          names = uniquifyParams (map identName params)
      in satDef ident names (generateExpr recNames body)

    -- | A self-tail-recursive one: the loop is a named function, and the
    -- method runs it.
    satTco :: [T.Text] -> P.Ident -> [P.Ident] -> CoreFn.Expr CoreFn.Ann -> T.Text
    satTco recNames ident params body =
      let names = uniquifyParams (map identName params)
          self = identName ident
          loopName = genPrefix <> "tco_" <> self
          stmts = tailStmts recNames self (length names) 1 body
      in "function " <> loopName <> "(" <> T.intercalate ", " names <> "); "
         <> T.intercalate "; " stmts <> "; end\n"
         <> satDef ident names
              ("(begin; _tco_r = (1, (" <> T.intercalate ", " names <> ",));"
               <> " while _tco_r[1] == 1; _tco_r = " <> loopName <> "(_tco_r[2]...); end;"
               <> " _tco_r[2]; end)")

    satDef :: P.Ident -> [T.Text] -> T.Text -> T.Text
    satDef ident names bodyTxt =
      let name = identName ident
          args = [ "_a" <> T.pack (show i) | i <- [0 .. length names - 1] ]
          wrapper = foldr (\a acc -> "((" <> a <> ") -> " <> acc <> ")")
                          (satName name <> "(" <> T.intercalate ", " args <> ")") args
      in satName name <> "(" <> T.intercalate ", " names <> ") = " <> bodyTxt
         <> "\n" <> name <> " = " <> wrapper

    -- ---------------------------------------------------------------
    -- Saturated calls and the inliner (ADR-0010)
    -- ---------------------------------------------------------------
    --
    -- An application spine whose head is a top-level name: an inliner rule
    -- for that name (purs's JS CoreImp set) replaces the call; else a known
    -- function of arity n is called through its method with the first n
    -- arguments; else a known constructor applied to all its fields is
    -- built in place. Each returns how many arguments it took; the rest are
    -- applied curried. Arguments are pure, and the intermediate closures of
    -- a lambda chain do nothing but capture, so no result changes.
    genApp :: [T.Text] -> CoreFn.Expr CoreFn.Ann -> Maybe T.Text
    genApp recNames e = case spine e of
      (CoreFn.Var _ (P.Qualified (P.ByModuleName mn) ident), args)
        | Just (k, r) <- inlineApp recNames mn ident args
                           `orElse` saturate recNames mn ident args
                           `orElse` throughAlias recNames mn ident args ->
            Just (foldl (\acc a -> "(" <> acc <> ")(" <> generateExpr recNames a <> ")")
                        r (drop k args))
      _ -> Nothing

    saturate :: [T.Text] -> P.ModuleName -> P.Ident -> [CoreFn.Expr CoreFn.Ann] -> Maybe (Int, T.Text)
    saturate recNames mn ident args = case Map.lookup (mn, ident) known of
      Just (KnownFn n) | length args >= n ->
        let qual = if mn == currentModule then "" else jlModuleAlias mn <> "."
        in Just (n, qual <> satName (identName ident) <> "(" <> gens (take n args) <> ")")
      Just (KnownCtor CtorNewtype) | (a : _) <- args -> Just (1, generateExpr recNames a)
      Just (KnownCtor (CtorData tag n)) | n > 0, length args >= n ->
        let as = map (generateExpr recNames) (take n args)
            slot i = if i < n then as !! i else "nothing"
            rest = if n > 3 then "(" <> T.concat [ x <> ", " | x <- drop 3 as ] <> ")" else "()"
        in Just (n, "PSData(\"" <> tag <> "\", " <> T.pack (show n) <> ", "
                    <> T.intercalate ", " [slot 0, slot 1, slot 2, rest] <> ")")
      Just (KnownCtor (CtorDict fields)) | not (null fields), length args >= length fields ->
        Just (length fields, "Dict{String,Any}("
          <> T.intercalate ", " [ "\"" <> escapeStringJl (runIdent' f) <> "\" => " <> generateExpr recNames a
                                | (f, a) <- zip fields args ]
          <> ")")
      _ -> Nothing
      where gens = T.intercalate ", " . map (generateExpr recNames)

    throughAlias :: [T.Text] -> P.ModuleName -> P.Ident -> [CoreFn.Expr CoreFn.Ann] -> Maybe (Int, T.Text)
    throughAlias recNames mn ident args = case Map.lookup (mn, ident) known of
      Just (KnownAlias amn aident pre)
        | let args' = pre ++ args
        , Just (k, r) <- inlineApp recNames amn aident args'
                           `orElse` saturate recNames amn aident args'
        , k > length pre -> Just (k - length pre, r)
      _ -> Nothing

    -- | purs's JS inliner (CoreImp/Optimizer/Inliner.hs), rule for rule. Fn
    -- values are n-ary Julia closures; an EffectFn runs its effect when
    -- called (the Data_Function_Uncurried and Effect_Uncurried shims).
    inlineApp :: [T.Text] -> P.ModuleName -> P.Ident -> [CoreFn.Expr CoreFn.Ann] -> Maybe (Int, T.Text)
    inlineApp recNames (P.ModuleName mn) (P.Ident fn) args
      | mn == "Data.Function.Uncurried", Just n <- suffix "runFn", n /= 1
      , (f : rest) <- args, length rest >= n =
          Just (n + 1, "(" <> gen f <> ")(" <> gens (take n rest) <> ")")
      | mn == "Data.Function.Uncurried", Just n <- suffix "mkFn", n /= 1
      , (f : _) <- args, Just r <- uncurried n f id = Just (1, r)
      | mn `elem` ["Effect.Uncurried", "Control.Monad.ST.Uncurried"]
      , Just n <- suffix "runEffectFn" `orElse` suffix "runSTFn", n >= 1
      , (f : rest) <- args, length rest >= n =
          Just (n + 1, "(() -> (" <> gen f <> ")(" <> gens (take n rest) <> "))")
      | mn `elem` ["Effect.Uncurried", "Control.Monad.ST.Uncurried"]
      , Just n <- suffix "mkEffectFn" `orElse` suffix "mkSTFn", n >= 1
      , (f : _) <- args, Just r <- uncurried n f (\b -> "(" <> b <> ")()") = Just (1, r)
      | (CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName dm)) (P.Ident dict)) : rest) <- args
      , Just op <- lookup (mn, fn, dm, dict) dictOps =
          case (op, rest) of
            (OpBinary o, x : y : _) -> Just (3, "(" <> gen x <> " " <> o <> " " <> gen y <> ")")
            (OpUnary o, x : _) -> Just (2, "(" <> o <> "(" <> gen x <> "))")
            (OpValue v, _) -> Just (1, v)
            _ -> Nothing
      | mn == "Data.Int.Bits", x : y : _ <- args, Just o <- lookup fn [("and", "&"), ("or", "|")] =
          Just (2, "(" <> gen x <> " " <> o <> " " <> gen y <> ")")
      | mn == "Data.Int.Bits", fn == "xor", x : y : _ <- args =
          Just (2, "Base.xor(" <> gen x <> ", " <> gen y <> ")")
      | mn == "Data.Array", fn == "unsafeIndex", CoreFn.Var {} : arr : i : _ <- args =
          Just (3, "(" <> gen arr <> ")[(" <> gen i <> ") + 1]")
      | mn == "Unsafe.Coerce", fn == "unsafeCoerce", x : _ <- args = Just (1, gen x)
      | mn == "Control.Category", fn == "identity"
      , CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName "Control.Category")) (P.Ident "categoryFn")) : x : _ <- args =
          Just (2, gen x)
      where
        gen = generateExpr recNames
        gens = T.intercalate ", " . map gen
        suffix pre = T.stripPrefix pre fn >>= readMaybe . T.unpack >>= \n ->
          if n >= 0 && n <= (10 :: Int) then Just n else Nothing
        -- @mkFnN (\a1 .. aN -> body)@ as an n-ary closure, when the argument
        -- is a lambda chain at least N deep (purs's @collectArgs@). @mkFn0@
        -- takes the one Unit-typed lambda and binds its parameter to nothing.
        uncurried n f finish =
          let (params, _) = peelAbs f
              taken = max n 1
              body = generateExpr recNames (dropAbs taken f)
              names = uniquifyParams (map identName (take taken params))
          in if length params < taken then Nothing
             else Just $ if n == 0
               then "(() -> (let " <> T.concat names <> " = nothing; " <> finish body <> " end))"
               else "((" <> T.intercalate ", " names <> ") -> " <> finish body <> ")"
    inlineApp _ _ _ _ = Nothing

    dropAbs :: Int -> CoreFn.Expr CoreFn.Ann -> CoreFn.Expr CoreFn.Ann
    dropAbs k (CoreFn.Abs _ _ b) | k > 0 = dropAbs (k - 1) b
    dropAbs _ e = e

    orElse :: Maybe a -> Maybe a -> Maybe a
    orElse (Just x) _ = Just x
    orElse Nothing y = y

    -- | Generate an expression, tracking names in the current top-level
    -- Rec group (references to those go through their lazy thunks)
    generateExpr :: [T.Text] -> CoreFn.Expr CoreFn.Ann -> T.Text
    generateExpr recNames = \case
      CoreFn.Literal _ lit -> generateLiteral recNames lit

      -- Prim.undefined
      CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName "Prim")) (P.Ident "undefined")) ->
        "nothing"

      CoreFn.Var _ qi -> generateQualifiedIdent recNames qi

      CoreFn.Abs _ arg body ->
        "((" <> identName arg <> ") -> " <> generateExpr recNames body <> ")"

      e@(CoreFn.App _ fn arg)
        | Just r <- genApp recNames e -> r
        | otherwise ->
            "(" <> generateExpr recNames fn <> ")(" <> generateExpr recNames arg <> ")"

      CoreFn.Let _ binds body ->
        iife (concatMap (generateLetBind recNames) binds) (generateExpr recNames body)

      CoreFn.Case _ exprs alts ->
        let (scrutCode, roots) = case exprs of
              [e] -> (generateExpr recNames e, ["__v__"])
              es -> ( "(" <> T.intercalate ", " (map (generateExpr recNames) es) <> ")"
                    , [ "__v__[" <> T.pack (show i) <> "]" | i <- [1 .. length es] ]
                    )
        in "((__v__) -> " <> generateAlternatives recNames roots alts <> ")(" <> scrutCode <> ")"

      CoreFn.Accessor _ field expr ->
        "(" <> generateExpr recNames expr <> ")[\"" <> psStringToText field <> "\"]"

      CoreFn.ObjectUpdate _ expr _ updates ->
        "merge(" <> generateExpr recNames expr <> ", Dict{String,Any}("
        <> T.intercalate ", " [ "\"" <> psStringToText k <> "\" => " <> generateExpr recNames v
                              | (k, v) <- updates ]
        <> "))"

      CoreFn.Constructor ann _ (P.ProperName ctor) fields ->
        constructorToJl ann ctor fields

    -- | Constructor declarations.
    constructorToJl :: CoreFn.Ann -> T.Text -> [P.Ident] -> T.Text
    constructorToJl ann ctor fields = case ann of
      -- Newtype constructor: identity
      (_, _, Just CoreFn.IsNewtype) -> "((__x) -> __x)"
      -- Typeclass dictionary constructor: build a record keyed by member
      -- name so Accessor works on the result
      (_, _, Just CoreFn.IsTypeClassConstructor) ->
        let dict = "Dict{String,Any}("
                   <> T.intercalate ", " [ "\"" <> escapeStringJl (runIdent' f) <> "\" => " <> identName f
                                         | f <- fields ]
                   <> ")"
        in curriedOver fields dict
      -- Data constructor: curried PSData builder (tag at [1], fields from [2])
      _ ->
        let n = length fields
            names = map identName fields
            slot i = if i < n then names !! i else "nothing"
            rest = if n > 3 then "(" <> T.concat [ x <> ", " | x <- drop 3 names ] <> ")" else "()"
            tup = "PSData(\"" <> escapeStringJl ctor <> "\", " <> T.pack (show n) <> ", "
                  <> T.intercalate ", " [slot 0, slot 1, slot 2, rest] <> ")"
        in curriedOver fields tup

    curriedOver :: [P.Ident] -> T.Text -> T.Text
    curriedOver fields body =
      foldr (\f acc -> "((" <> identName f <> ") -> " <> acc <> ")") body fields

    -- | Let bindings become statements inside an IIFE. Local recursion
    -- works via closure capture of boxed locals - no thunks needed.
    generateLetBind :: [T.Text] -> CoreFn.Bind CoreFn.Ann -> [T.Text]
    generateLetBind recNames (CoreFn.NonRec _ ident expr) =
      [identName ident <> " = " <> generateExpr recNames expr]
    generateLetBind recNames (CoreFn.Rec bindings) =
      -- Self-tail-recursive local bindings (the classic `go`) get the
      -- trampoline; the rest rely on closure capture of boxed locals.
      ("local " <> T.intercalate ", " [identName ident | ((_, ident), _) <- bindings])
      : [ case tryTco (identName ident) expr of
            Just (ps, body) ->
              identName ident <> " = " <> generateTcoExpr recNames (identName ident) ps body
            Nothing ->
              identName ident <> " = " <> generateExpr recNames expr
        | ((_, ident), expr) <- bindings
        ]

    -- | Immediately-invoked function expression: statement scope inside
    -- an expression. The last expression is the value.
    iife :: [T.Text] -> T.Text -> T.Text
    iife [] body = body
    iife stmts body =
      "((function (); " <> T.intercalate "; " stmts <> "; " <> body <> "; end)())"

    -- | Pattern matching alternatives as a chain of ternaries
    generateAlternatives :: [T.Text] -> [T.Text] -> [CoreFn.CaseAlternative CoreFn.Ann] -> T.Text
    generateAlternatives recNames roots alts =
      foldr (generateAlt recNames roots) failCase alts
      where
        failCase = "Base.error(\"Pattern match failed in module "
                   <> escapeStringJl currentModuleText <> "\")"

    generateAlt :: [T.Text] -> [T.Text] -> CoreFn.CaseAlternative CoreFn.Ann -> T.Text -> T.Text
    generateAlt recNames roots (CoreFn.CaseAlternative binders result) rest =
      let patResults = zipWith (generatePattern recNames) roots binders
          conds = filter (/= "true") (map fst patResults)
          allBindings = concatMap snd patResults
          combinedCond = case conds of
            [] -> "true"
            _ -> T.intercalate " && " conds
          bodyCode = case result of
            Right body -> generateExpr recNames body
            Left guards ->
              let generateGuards [] = rest
                  generateGuards ((g, b):gs) =
                    "(" <> generateExpr recNames g <> " ? "
                    <> generateExpr recNames b <> " : " <> generateGuards gs <> ")"
              in generateGuards guards
          withBindings = if null allBindings
                           then bodyCode
                           else iife allBindings bodyCode
      in if combinedCond == "true"
           then withBindings
           else "(" <> combinedCond <> " ? (" <> withBindings <> ") : (" <> rest <> "))"

    -- | Generate (condition, [binding statements]) for a binder against a
    -- scrutinee expression
    generatePattern :: [T.Text] -> T.Text -> CoreFn.Binder CoreFn.Ann -> (T.Text, [T.Text])
    generatePattern _ scrutinee (CoreFn.VarBinder _ ident) =
      ("true", [identName ident <> " = " <> scrutinee])
    generatePattern _ _ (CoreFn.NullBinder _) =
      ("true", [])
    generatePattern recNames scrutinee (CoreFn.LiteralBinder _ lit) =
      case lit of
        CoreFn.NumericLiteral (Left n) ->
          (scrutinee <> " == " <> T.pack (show n), [])
        CoreFn.NumericLiteral (Right n) ->
          (scrutinee <> " == " <> T.pack (show n), [])
        CoreFn.StringLiteral s ->
          (scrutinee <> " == \"" <> psStringToText s <> "\"", [])
        CoreFn.CharLiteral c ->
          (scrutinee <> " == '" <> escapeCharJl c <> "'", [])
        CoreFn.BooleanLiteral True ->
          (scrutinee <> " == true", [])
        CoreFn.BooleanLiteral False ->
          (scrutinee <> " == false", [])
        CoreFn.ArrayLiteral binders ->
          let lenCheck = "Base.length(" <> scrutinee <> ") == " <> T.pack (show (length binders))
              elemPatterns = zipWith
                (\i b -> generatePattern recNames (scrutinee <> "[" <> T.pack (show (i :: Int)) <> "]") b)
                [1..] binders
              elemConds = filter (/= "true") $ map fst elemPatterns
              elemBindings = concatMap snd elemPatterns
              combinedCond = T.intercalate " && " (lenCheck : elemConds)
          in (combinedCond, elemBindings)
        CoreFn.ObjectLiteral fields ->
          let fieldPatterns = map
                (\(fieldName, binder) ->
                   generatePattern recNames (scrutinee <> "[\"" <> psKey fieldName <> "\"]") binder)
                fields
              fieldConds = filter (/= "true") $ map fst fieldPatterns
              fieldBindings = concatMap snd fieldPatterns
              combinedCond = case fieldConds of
                [] -> "true"
                _ -> T.intercalate " && " fieldConds
          in (combinedCond, fieldBindings)
    generatePattern recNames scrutinee (CoreFn.ConstructorBinder ann _tyName (P.Qualified _ (P.ProperName ctorName)) subBinders) =
      case ann of
        (_, _, Just CoreFn.IsNewtype) ->
          -- Newtype: the value IS the wrapped value
          case subBinders of
            [inner] -> generatePattern recNames scrutinee inner
            _ -> ("true", [])
        _ ->
          -- Tag at [1], fields from [2]
          let tagCheck = scrutinee <> "[1] == \"" <> escapeStringJl ctorName <> "\""
              fieldPatterns = zipWith
                (\i b -> generatePattern recNames (scrutinee <> "[" <> T.pack (show (i :: Int)) <> "]") b)
                [2..] subBinders
              fieldConds = filter (/= "true") $ map fst fieldPatterns
              fieldBindings = concatMap snd fieldPatterns
              combinedCond = T.intercalate " && " (tagCheck : fieldConds)
          in (combinedCond, fieldBindings)
    generatePattern recNames scrutinee (CoreFn.NamedBinder _ ident inner) =
      let (innerCond, innerBindings) = generatePattern recNames scrutinee inner
          binding = identName ident <> " = " <> scrutinee
      in (innerCond, binding : innerBindings)

    -- ---------------------------------------------------------------
    -- Tail-call optimization
    -- ---------------------------------------------------------------

    unApp :: CoreFn.Expr CoreFn.Ann -> (CoreFn.Expr CoreFn.Ann, [CoreFn.Expr CoreFn.Ann])
    unApp = go []
      where
        go args (CoreFn.App _ fn arg) = go (arg : args) fn
        go args other = (other, args)

    peelAbs :: CoreFn.Expr CoreFn.Ann -> ([P.Ident], CoreFn.Expr CoreFn.Ann)
    peelAbs (CoreFn.Abs _ arg body) =
      let (ps, b) = peelAbs body in (arg : ps, b)
    peelAbs other = ([], other)

    -- | Is this expression a Var referring to the named local binding?
    isSelfVar :: T.Text -> CoreFn.Expr CoreFn.Ann -> Bool
    isSelfVar self (CoreFn.Var _ (P.Qualified qb ident)) =
      identName ident == self && case qb of
        P.ByModuleName mn -> mn == currentModule
        P.BySourcePos _ -> True
    isSelfVar _ _ = False

    -- | TCO applicability: the binding must be a lambda chain whose body
    -- references itself ONLY as fully-saturated tail calls (and at least
    -- once). Returns the peeled params and body when applicable.
    tryTco :: T.Text -> CoreFn.Expr CoreFn.Ann -> Maybe ([P.Ident], CoreFn.Expr CoreFn.Ann)
    tryTco self expr =
      let (params, body) = peelAbs expr
          n = length params
      in if n > 0 && hasSelfTailCall self n body && tcoOk self n True body
           then Just (params, body)
           else Nothing

    -- | Does any tail position contain a saturated self call?
    hasSelfTailCall :: T.Text -> Int -> CoreFn.Expr CoreFn.Ann -> Bool
    hasSelfTailCall self n = go
      where
        go expr = case expr of
          e@(CoreFn.App {}) ->
            let (fn, args) = unApp e
            in isSelfVar self fn && length args == n
          CoreFn.Case _ _ alts ->
            let altHas (CoreFn.CaseAlternative _ result) = case result of
                  Right b -> go b
                  Left guards -> any (go . snd) guards
            in any altHas alts
          CoreFn.Let _ _ body -> go body
          _ -> False

    -- | Walk with a tail-position flag; False means disqualified. Self
    -- references are only allowed as exact-arity applications in tail
    -- position; a self reference inside a nested lambda, an argument, a
    -- scrutinee, a guard condition, or a let RHS disqualifies.
    tcoOk :: T.Text -> Int -> Bool -> CoreFn.Expr CoreFn.Ann -> Bool
    tcoOk self n = go
      where
        noSelf e = not (Set.member self (collectLocalRefs currentModule e))
        go tailPos expr = case expr of
          e@(CoreFn.App {}) ->
            let (fn, args) = unApp e
            in if isSelfVar self fn
                 then tailPos && length args == n && all (go False) args
                 else go False fn && all (go False) args
          v@(CoreFn.Var {}) -> not (isSelfVar self v)
          CoreFn.Abs _ _ body -> noSelf body
          CoreFn.Case _ scruts alts ->
            let altOk (CoreFn.CaseAlternative _ result) = case result of
                  Right b -> go tailPos b
                  Left guards -> all (\(g, b) -> go False g && go tailPos b) guards
            in all (go False) scruts && all altOk alts
          CoreFn.Let _ binds body ->
            let bindOk (CoreFn.NonRec _ _ e) = go False e
                bindOk (CoreFn.Rec bs) = all (go False . snd) bs
            in all bindOk binds && go tailPos body
          CoreFn.Accessor _ _ e -> go False e
          CoreFn.ObjectUpdate _ e _ updates ->
            go False e && all (go False . snd) updates
          CoreFn.Literal _ lit -> case lit of
            CoreFn.ArrayLiteral es -> all (go False) es
            CoreFn.ObjectLiteral fs -> all (go False . snd) fs
            _ -> True
          CoreFn.Constructor {} -> True

    -- | Rename earlier duplicates in a param list (shadowed/unused
    -- params); the body only ever sees the last occurrence.
    uniquifyParams :: [T.Text] -> [T.Text]
    uniquifyParams = go (0 :: Int)
      where
        go _ [] = []
        go i (name : rest)
          | name `elem` rest = (name <> "__" <> T.pack (show i)) : go (i + 1) rest
          | otherwise = name : go (i + 1) rest

    -- | Emit the trampolined form (a single expression, one line).
    generateTcoExpr :: [T.Text] -> T.Text -> [P.Ident] -> CoreFn.Expr CoreFn.Ann -> T.Text
    generateTcoExpr recNames self params body =
      let names = uniquifyParams (map identName params)
          n = length names
          stmts = tailStmts recNames self n 1 body
          loopFn = "function _tco_loop(" <> T.intercalate ", " names <> "); "
                   <> T.intercalate "; " stmts <> "; end"
          wrapperBody = "(begin; _tco_r = (1, (" <> T.intercalate ", " names <> ",));"
                        <> " while _tco_r[1] == 1; _tco_r = _tco_loop(_tco_r[2]...); end;"
                        <> " _tco_r[2]; end)"
          wrapper = foldr (\p acc -> "((" <> p <> ") -> " <> acc <> ")") wrapperBody names
      in "(function (); " <> loopFn <> "; " <> wrapper <> "; end)()"

    -- | Compile an expression in tail position of a TCO loop function.
    -- Every control path ends in @return (1, (args...,))@ (loop again),
    -- @return (0, value)@ (done), or a raised pattern-match error.
    tailStmts :: [T.Text] -> T.Text -> Int -> Int -> CoreFn.Expr CoreFn.Ann -> [T.Text]
    tailStmts recNames self n depth expr = case expr of
      e@(CoreFn.App {})
        | (fn, args) <- unApp e
        , isSelfVar self fn
        , length args == n ->
          [ "return (1, (" <> T.intercalate ", " (map (generateExpr recNames) args) <> ",))" ]
      CoreFn.Let _ binds body ->
        concatMap (generateLetBind recNames) binds
        ++ tailStmts recNames self n depth body
      CoreFn.Case _ scruts alts ->
        let v = "__v_t" <> T.pack (show depth) <> "__"
            (scrutCode, roots) = case scruts of
              [e] -> (generateExpr recNames e, [v])
              es -> ( "(" <> T.intercalate ", " (map (generateExpr recNames) es) <> ")"
                    , [ v <> "[" <> T.pack (show i) <> "]" | i <- [1 .. length es] ]
                    )
            -- Alternatives are sequential if-blocks: every body exits via
            -- return/error, so falling out of an if means "try the next
            -- alternative" - which is exactly PS guard fall-through.
            altStmts (CoreFn.CaseAlternative binders result) =
              let patResults = zipWith (generatePattern recNames) roots binders
                  conds = filter (/= "true") (map fst patResults)
                  bindings = concatMap snd patResults
                  cond = case conds of
                    [] -> "true"
                    _ -> T.intercalate " && " conds
                  inner = case result of
                    Right b -> tailStmts recNames self n (depth + 1) b
                    Left guards ->
                      [ "if " <> generateExpr recNames g <> "; "
                        <> T.intercalate "; " (tailStmts recNames self n (depth + 1) b)
                        <> "; end"
                      | (g, b) <- guards
                      ]
              in "if " <> cond <> "; "
                 <> T.intercalate "; " (bindings ++ inner)
                 <> "; end"
        in (v <> " = " <> scrutCode)
           : map altStmts alts
           ++ [ "Base.error(\"Pattern match failed in module "
                <> escapeStringJl currentModuleText <> "\")" ]
      other -> [ "return (0, " <> generateExpr recNames other <> ")" ]

    generateLiteral :: [T.Text] -> CoreFn.Literal (CoreFn.Expr CoreFn.Ann) -> T.Text
    generateLiteral recNames = \case
      CoreFn.NumericLiteral (Left n) -> T.pack (show n)
      CoreFn.NumericLiteral (Right n) -> T.pack (show n)
      CoreFn.StringLiteral s -> "\"" <> psStringToText s <> "\""
      CoreFn.CharLiteral c -> "'" <> escapeCharJl c <> "'"
      CoreFn.BooleanLiteral True -> "true"
      CoreFn.BooleanLiteral False -> "false"
      CoreFn.ArrayLiteral exprs ->
        "Any[" <> T.intercalate ", " (map (generateExpr recNames) exprs) <> "]"
      CoreFn.ObjectLiteral fields ->
        "Dict{String,Any}("
        <> T.intercalate ", " [ "\"" <> psStringToText k <> "\" => " <> generateExpr recNames v
                              | (k, v) <- fields ]
        <> ")"

    psKey :: PSString -> T.Text
    psKey s = case decodeString s of
      Just str -> escapeStringJl str
      Nothing -> psStringToText s

    generateQualifiedIdent :: [T.Text] -> P.Qualified P.Ident -> T.Text
    generateQualifiedIdent recNames (P.Qualified qb ident) =
      let name = identName ident
          -- Names in the current Rec group go through their lazy thunk
          maybeCallLazyThunk n = if n `elem` recNames then "_lazy_" <> n <> "()" else n
      in case qb of
        P.ByModuleName mn
          | mn == currentModule -> maybeCallLazyThunk name
          | otherwise -> jlModuleAlias mn <> "." <> name
        P.BySourcePos _ -> maybeCallLazyThunk name

-- | Collect all references to local (same-module or source-pos-qualified)
-- names from an expression - used for smart Rec partitioning
collectLocalRefs :: P.ModuleName -> CoreFn.Expr CoreFn.Ann -> Set.Set T.Text
collectLocalRefs currentMod = go
  where
    go :: CoreFn.Expr CoreFn.Ann -> Set.Set T.Text
    go = \case
      CoreFn.Literal _ lit -> goLit lit
      CoreFn.Var _ (P.Qualified qb ident) ->
        case qb of
          P.ByModuleName mn | mn == currentMod -> Set.singleton (identToJlName ident)
          P.BySourcePos _ -> Set.singleton (identToJlName ident)
          _ -> Set.empty
      CoreFn.Abs _ _ body -> go body
      CoreFn.App _ fn arg -> go fn <> go arg
      CoreFn.Let _ binds body -> foldMap goBind binds <> go body
      CoreFn.Case _ exprs alts -> foldMap go exprs <> foldMap goAlt alts
      CoreFn.Accessor _ _ expr -> go expr
      CoreFn.ObjectUpdate _ expr _ updates -> go expr <> foldMap (go . snd) updates
      CoreFn.Constructor {} -> Set.empty

    goLit :: CoreFn.Literal (CoreFn.Expr CoreFn.Ann) -> Set.Set T.Text
    goLit = \case
      CoreFn.ArrayLiteral exprs -> foldMap go exprs
      CoreFn.ObjectLiteral fields -> foldMap (go . snd) fields
      _ -> Set.empty

    goBind :: CoreFn.Bind CoreFn.Ann -> Set.Set T.Text
    goBind (CoreFn.NonRec _ _ expr) = go expr
    goBind (CoreFn.Rec bindings) = foldMap (go . snd) bindings

    goAlt :: CoreFn.CaseAlternative CoreFn.Ann -> Set.Set T.Text
    goAlt (CoreFn.CaseAlternative _ result) =
      case result of
        Left guards -> foldMap (\(g, b) -> go g <> go b) guards
        Right body -> go body
