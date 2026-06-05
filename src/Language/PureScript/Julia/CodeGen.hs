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
--   * ADT values are tag-tuples: @("Just", x)@, nullary @("Nothing",)@.
--     Tag at index 1, fields from index 2 (Julia is 1-based).
--   * Newtype constructors are identity functions.
--   * Typeclass dictionaries are @Dict{String,Any}@ records keyed by
--     member name, so CoreFn's @Accessor@ works uniformly.
--   * Records are @Dict{String,Any}@; update is @merge@.
--   * Arrays are @Any[...]@ vectors.
--   * Effects are zero-argument closures (thunks).
--   * Functions are curried unary closures; application is @(f)(x)(y)@.
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
  ) where

import Prelude

import Data.List (partition)
import qualified Data.Set as Set
import qualified Data.Text as T

import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import Language.PureScript.PSString (PSString, decodeString)

import Language.PureScript.Julia.CodeGen.Common

-- | Generate the Julia body (declarations only, no module header) for a module
generateModuleJl :: CoreFn.Module CoreFn.Ann -> T.Text
generateModuleJl cfModule = T.unlines $ map (generateBinding []) (CoreFn.moduleDecls cfModule)
  where
    currentModule :: P.ModuleName
    currentModule = CoreFn.moduleName cfModule

    currentModuleText :: T.Text
    currentModuleText = case currentModule of
      P.ModuleName mn -> mn

    -- | Generate a top-level binding, tracking names in the current Rec group
    generateBinding :: [T.Text] -> CoreFn.Bind CoreFn.Ann -> T.Text
    generateBinding _ (CoreFn.NonRec _ ident expr) =
      identName ident <> " = " <> generateExpr [] expr
    generateBinding _ (CoreFn.Rec bindings) =
      -- Rec handling, in order of preference per binding:
      --   1. TCO: all self-refs are saturated tail calls -> dispatch loop,
      --      plain assignment, no thunk (other-member refs resolve at call
      --      time, or through _lazy_X() for thunked members).
      --   2. Smart thunk partition: only bindings that reference remaining
      --      group members go through the lazy-thunk runtime.
      let tcoAnnotated = [ (b, tryTco (identName ident) expr)
                         | b@((_, ident), expr) <- bindings ]
          tcoBindings = [ (ident, ps, body)
                        | (((_, ident), _), Just (ps, body)) <- tcoAnnotated ]
          plainBindings = [ b | (b, Nothing) <- tcoAnnotated ]
          allNames = Set.fromList [identName ident | ((_, ident), _) <- plainBindings]
          needsThunk ((_, _ident), expr) =
            not $ Set.null $ Set.intersection (collectLocalRefs currentModule expr) allNames
          (recursive, nonRecursive) = partition needsThunk plainBindings
          recNames = [identName ident | ((_, ident), _) <- recursive]
          tcoDefs = [ identName ident <> " = "
                      <> generateTcoExpr recNames (identName ident) ps body
                    | (ident, ps, body) <- tcoBindings
                    ]
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

      CoreFn.App _ fn arg ->
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
      -- Data constructor: curried tag-tuple builder
      _ ->
        let tup = if null fields
                    then "(\"" <> escapeStringJl ctor <> "\",)"
                    else "(\"" <> escapeStringJl ctor <> "\", "
                         <> T.intercalate ", " (map identName fields) <> ")"
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
          | otherwise -> jlModuleName mn <> "." <> name
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
