-- | Julia codegen over the backend-optimizer's optimized IR ('NeutralExpr').
-- |
-- | This is the optimizer-consumer lane for Jurist (`purejl` is the oracle; see
-- | the family decision in `docs/kb/architecture/adopt-backend-optimizer-family-wide.md`).
-- | It emits ONE JULIA MODULE PER PURESCRIPT MODULE, named and imported exactly as
-- | `purejl` names them, so the *same* `purejl_runtime.jl` and the *same*
-- | `<Module>_foreign.jl` shims serve both lanes. That is deliberate: Gnomon's two
-- | forked Go runtimes silently diverged by two symbols and needed a red CI to
-- | find. Here a fork is not possible -- the runtime and the foreigns are produced
-- | by `purejl` and consumed unmodified.
-- |
-- | EXPRESSION-ORIENTED, and this is where it parts company with `backend-py`.
-- | Python's `lambda` takes an expression, so `backend-py` had to emit statements,
-- | and paid for it: an IR scope stopped being a target scope, and four separate
-- | name-collision classes followed. Julia has no such tension. `let x = v; body end`
-- | and `if c; a; else; b; end` are BOTH scoped blocks AND expressions, so a `Let`
-- | lowers to a `let` and a `Branch` to an `if`/`elseif` chain with no statement
-- | buffer, no lambda lifting, and no renaming pass. Every IR scope is a real Julia
-- | scope again, exactly as in `backend-go` -- but without `backend-go`'s IIFE
-- | per binding.
-- |
-- | The one place statements are unavoidable is a TCO loop body, which has to
-- | `return` a continue/stop signal. That walk (`genLoopStmts`) is the only
-- | statement-mode code here, and it uses `let` for its bindings so the scoping
-- | guarantee holds there too.
-- |
-- | Representation is `purejl`'s (it has to be -- the foreigns are shared), and it
-- | is 1-BASED throughout, which is the systematic difference from the Python lane:
-- | ADTs are tag-tuples `("Just", x)` with the tag at index 1 and field *i* at
-- | *i+2*; records and dictionaries are `Dict{String,Any}`; arrays are `Any[]`
-- | vectors indexed from 1 while the PureScript API is 0-based; chars are Julia
-- | `Char`; `Effect a` is a zero-argument closure; a `Ref` is a one-element `Any[]`;
-- | functions are curried unary closures; `Int` is `Int64` (Jurist ADR-0001's
-- | deliberate divergence from JS int32, so ordinary arithmetic does NOT wrap --
-- | only `Data.Int.Bits` does).
-- |
-- | DELIBERATE SLICES (each named, none accidental):
-- |
-- |   * Curried `Abs`/`App` as in `backend-go` and `backend-es`: the optimizer's
-- |     `App f args` is a syntactic spine, not a saturation guarantee, so native
-- |     n-ary emission would be unsound. `Uncurried*` (Fn/EffectFn) nodes DO emit
-- |     native multi-arg closures.
-- |   * TCO is an inline `while` over a tagged pair, the shape `purejl` already
-- |     uses (ADR-0003) -- so this lane needs NO runtime change for it. The
-- |     function-call-per-iteration is not an oversight: mutating the loop
-- |     parameters in place would box and share them across iterations, and any
-- |     closure built in the body would capture the last iteration's bindings.
-- |     Self-recursion and MUTUAL recursion both lower to it; mutual adds a
-- |     leading branch register, which is a codegen change only.
-- |   * Laziness is applied only where it is needed -- a recursive top-level group
-- |     that is not all-functions -- rather than uniformly. Julia resolves
-- |     module-level names late, so a recursive group of functions needs no
-- |     thunking, and keeping plain bindings plain is what lets a shared foreign
-- |     value be referenced without forcing.
module PureScript.Backend.Optimizer.Codegen.Julia
  ( Env
  , ModuleOutput
  , codegenModule
  , lazyIdentsOf
  , jlModuleName
  , jlModuleAlias
  , jlForeignFileName
  , jlIdent
  , jlFileName
  , runtimeImport
  ) where

import Prelude

import Control.Alternative (guard)
import Control.Monad.State (State, get, modify_, put, runState)
import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Char (toCharCode)
import Data.Foldable (foldMap)
import Data.Int (hexadecimal, toStringAs)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Newtype (unwrap)
import Data.Number as Number
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.String.CodeUnits as SCU
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Optimizer.Codegen.Tco (LocalRef, TcoAnalysis(..), TcoExpr(..), TcoRef(..), analyze, tcoRoleIsLoop, topLevelTcoEnvGroup, topLevelTcoRefBindings)
import PureScript.Backend.Optimizer.Convert (BackendBindingGroup, BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ident(..), Literal(..), ModuleName(..), Prop(..), Qualified(..))
import PureScript.Backend.Optimizer.Semantics (NeutralExpr)
import PureScript.Backend.Optimizer.Syntax (BackendAccessor(..), BackendEffect(..), BackendOperator(..), BackendOperator1(..), BackendOperator2(..), BackendOperatorNum(..), BackendOperatorOrd(..), BackendSyntax(..), Level(..), Pair(..))

--------------------------------------------------------------------------------
-- Environment and output
--------------------------------------------------------------------------------

-- | `lazyIdents` is the whole-program set of top-level bindings emitted as
-- | `_runtime_lazy` thunks; a reference to one is forced with a trailing `()`.
-- | It is computed by `lazyIdentsOf` over every module before any is emitted,
-- | because the decision is per-*definition* and the reference can be anywhere.
type Env =
  { currentModule :: ModuleName
  , lazyIdents :: Set (Qualified Ident)
  }

type ModuleOutput =
  { lines :: Array String
  -- | Modules actually referenced, so the header imports exactly what is used
  -- | (`BackendModule.imports` is pre-pruning and would name modules that entry
  -- | reachability has since deleted -- importing one is an UndefVarError).
  , used :: Set ModuleName
  }

-- | The runtime names this codegen emits calls to. All are defined by `purejl`'s
-- | own `purejl_runtime.jl`; nothing here writes a runtime.
-- |
-- | `_js_number_string` is imported although this file never calls it: the
-- | `<Module>_foreign.jl` shims are `include`d INTO this module, and
-- | `Data_Show_foreign.jl` and `Data_Number_Format_foreign.jl` both call it, so
-- | the name has to resolve in the including module's scope.
runtimeImport :: String
runtimeImport =
  "import ..PurejlRuntime: _runtime_lazy, _js_number_string, _int32, _int_div, _zshr"

--------------------------------------------------------------------------------
-- The emit monad
--------------------------------------------------------------------------------

-- | Unlike the Python lane there is no statement buffer: expressions are built as
-- | strings, and the only mutable state is the fresh counter and the set of
-- | modules actually referenced. The loop walk (`genLoopStmts`) returns its lines
-- | rather than emitting them.
type GenState =
  { fresh :: Int
  , used :: Set ModuleName
  }

type Gen = State GenState

freshName :: String -> Gen String
freshName prefix = do
  st <- get
  put st { fresh = st.fresh + 1 }
  pure (prefix <> show st.fresh)

noteModule :: ModuleName -> Gen Unit
noteModule mn = modify_ \st -> st { used = Set.insert mn st.used }

indent :: Array String -> Array String
indent = map ("    " <> _)

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

codegenModule :: Env -> BackendModule -> ModuleOutput
codegenModule env mod =
  let
    Tuple lines st = runState (map Array.concat (traverse (genGroup env) mod.bindings))
      { fresh: 0, used: Set.empty }
  in
    { lines, used: st.used }

--------------------------------------------------------------------------------
-- Binding groups
--------------------------------------------------------------------------------

-- | How one top-level binding group is emitted. Deciding this in one place
-- | matters: `lazyIdentsOf` (which runs first, over every module) and `genGroup`
-- | must agree exactly, or a reference forces something that was never thunked.
data GroupPlan
  = PlanLoop (NonEmptyArray LoopBinding) -- ^ optimizer says isLoop: `while` dispatch
  | PlanLazy -- ^ recursive, not all functions: `_runtime_lazy` + forced references
  | PlanPlain -- ^ plain assignments in order

type GroupAnalysis =
  { analyzed :: NonEmptyArray (Tuple Ident TcoExpr)
  , plan :: GroupPlan
  }

analyzeGroup :: ModuleName -> BackendBindingGroup Ident NeutralExpr -> Maybe GroupAnalysis
analyzeGroup mn grp = do
  binds <- NEA.fromArray grp.bindings
  let tenv = if grp.recursive then topLevelTcoEnvGroup mn binds else []
  let analyzed = map (\(Tuple i e) -> Tuple i (analyze tenv e)) binds
  let
    plan
      | not grp.recursive = PlanPlain
      | Just members <- topLevelLoopMembers mn analyzed = PlanLoop members
      -- Julia looks module-level names up at call time, so a recursive group of
      -- functions resolves itself with no thunking; anything else in the group
      -- can be referenced before it is assigned, and must be lazy.
      | Array.all (isFunctionShaped <<< snd) (NEA.toArray analyzed) = PlanPlain
      | otherwise = PlanLazy
  pure { analyzed, plan }

topLevelLoopMembers :: ModuleName -> NonEmptyArray (Tuple Ident TcoExpr) -> Maybe (NonEmptyArray LoopBinding)
topLevelLoopMembers mn analyzed = do
  refBindings <- topLevelTcoRefBindings mn analyzed
  guard (tcoRoleIsLoop refBindings)
  traverse loopBindingOf analyzed

isFunctionShaped :: TcoExpr -> Boolean
isFunctionShaped (TcoExpr _ syn) = case syn of
  Abs _ _ -> true
  UncurriedAbs _ _ -> true
  UncurriedEffectAbs _ _ -> true
  -- A constructor builder is a closed value: it captures nothing from the group.
  CtorDef _ _ _ _ -> true
  _ -> false

-- | The whole-program set of bindings that must be forced at their reference
-- | sites. Runs over every module before emission (see `Env.lazyIdents`).
lazyIdentsOf :: BackendModule -> Set (Qualified Ident)
lazyIdentsOf mod = foldMap groupLazy mod.bindings
  where
  groupLazy grp = case analyzeGroup mod.name grp of
    Just { analyzed, plan: PlanLazy } ->
      Set.fromFoldable (map (\(Tuple ident _) -> Qualified (Just mod.name) ident) (NEA.toArray analyzed))
    _ -> Set.empty

genGroup :: Env -> BackendBindingGroup Ident NeutralExpr -> Gen (Array String)
genGroup env grp = case analyzeGroup env.currentModule grp of
  Nothing -> pure []
  Just { analyzed, plan } -> case plan of
    PlanLoop members ->
      genLoopGroup env jlIdent (TcoTopLevel <<< Qualified (Just env.currentModule)) members
    -- A plain top-level binding is one assignment. Nothing has to be wrapped: a
    -- `Let` inside the value is a `let` block, which is an expression AND its own
    -- scope, so the sibling-collision hazard that forced `backend-py` to bury
    -- every top-level binding in an `_init_` function does not arise here.
    PlanPlain -> traverse
      ( \(Tuple ident expr) -> do
          e <- genExpr env expr
          pure (jlIdent ident <> " = " <> e)
      )
      (NEA.toArray analyzed)
    PlanLazy -> traverse
      ( \(Tuple ident expr) -> do
          e <- genExpr env expr
          let name = jlIdent ident
          pure
            ( name <> " = _runtime_lazy(" <> jlStr name <> ", "
                <> jlStr (unwrap env.currentModule)
                <> ", () -> "
                <> e
                <> ")"
            )
      )
      (NEA.toArray analyzed)

--------------------------------------------------------------------------------
-- Tail-call loops
--------------------------------------------------------------------------------

type LoopBinding =
  { ident :: Ident
  , params :: NonEmptyArray (Tuple (Maybe Ident) Level)
  , body :: TcoExpr
  }

-- | One branch of a dispatch group. `wrapper` is `Just` for an ORIGINAL member of
-- | the recursive group (which is a value the program can reference, so it needs
-- | a curried wrapper) and `Nothing` for a folded-in JOIN POINT (which is only
-- | ever jumped to, so it has no value form at all).
type GroupMember =
  { ref :: TcoRef
  , params :: Array LocalRef
  , body :: TcoExpr
  , wrapper :: Maybe Ident
  }

-- | What counts as a tail call while walking a loop body, and how the dispatch
-- | tuple is laid out.
-- |
-- | `layout` is the register file, and it is keyed by LOCAL rather than by
-- | position: one slot per distinct local bound by any branch. That is what makes
-- | join points work. A join point captures variables from the member it was
-- | defined inside (`tco4`'s `g y' = f (x + 2) y'` reads `f`'s parameter `x`),
-- | and a jump leaves the frame, so a captured variable has to travel in a
-- | register. Keying by local means `x` gets ONE slot whether it arrives as
-- | `f`'s parameter or as `g`'s captured free variable, and every branch binds
-- | every slot on entry — so at any jump site, every slot is in scope and can be
-- | passed on.
type LoopCtx =
  { members :: Array { ref :: TcoRef, arity :: Int, params :: Array LocalRef }
  , layout :: Array LocalRef
  , argNames :: Array String
  , branching :: Boolean
  }

loopBindingOf :: Tuple Ident TcoExpr -> Maybe LoopBinding
loopBindingOf (Tuple ident (TcoExpr _ (Abs params body))) = Just { ident, params, body }
loopBindingOf _ = Nothing

localNameOf :: LocalRef -> String
localNameOf (Tuple mbId lvl) = localName mbId lvl

--------------------------------------------------------------------------------
-- Join points
--------------------------------------------------------------------------------

-- | The free local variables of an expression: every `Local` reference not bound
-- | by an enclosing binder within it.
-- |
-- | Needed only for join points. A join point's body is lifted out of the member
-- | it was written inside and becomes a sibling branch, so anything it captured
-- | from that member has to be passed explicitly.
freeLocals :: TcoExpr -> Set LocalRef
freeLocals (TcoExpr _ syn) = case syn of
  Local mbId lvl -> Set.singleton (Tuple mbId lvl)
  Abs params body -> without (NEA.toArray params) (freeLocals body)
  UncurriedAbs params body -> without params (freeLocals body)
  UncurriedEffectAbs params body -> without params (freeLocals body)
  Let mbId lvl val body -> freeLocals val <> without [ Tuple mbId lvl ] (freeLocals body)
  EffectBind mbId lvl val body -> freeLocals val <> without [ Tuple mbId lvl ] (freeLocals body)
  LetRec lvl bindings body ->
    without (map (\(Tuple ident _) -> Tuple (Just ident) lvl) (NEA.toArray bindings))
      (foldMap (freeLocals <<< snd) (NEA.toArray bindings) <> freeLocals body)
  _ -> foldMap freeLocals syn
  where
  without bs = flip Set.difference (Set.fromFoldable bs)

-- | Does this node's `joins` role name a member of the group being emitted?
-- |
-- | The check matters because `joins` is computed against whatever TCO scope was
-- | in force where the node sits, and loops nest: a `Let` deep inside a nested
-- | loop can be a join point of the OUTER group, and folding it into the inner
-- | one would be wrong.
joinsThisGroup :: Array TcoRef -> TcoAnalysis -> Boolean
joinsThisGroup groupRefs (TcoAnalysis a) = Array.any (flip Array.elem groupRefs) a.role.joins

-- | Collect the join points reachable in TAIL position from a member's body.
-- |
-- | Recurses into a join point's own body, because join points nest: `tco2` has
-- | `f` tail-call `g`, `g` tail-call `h`, and `h` tail-call `f`.
-- |
-- | A nested `LetRec` that is a loop but NOT a join of this group is left alone —
-- | it owns its own trampoline, and its members are not branches of ours.
collectJoins :: Array TcoRef -> TcoExpr -> Array GroupMember
collectJoins groupRefs = go
  where
  go (TcoExpr ann syn) = case syn of
    Let mbId lvl val rest
      | joinsThisGroup groupRefs ann
      , TcoExpr _ (Abs params body) <- val ->
          [ { ref: TcoLocal mbId lvl
            , params: NEA.toArray params
            , body
            , wrapper: Nothing
            }
          ] <> go body <> go rest
      | otherwise -> go rest

    LetRec lvl bindings rest
      | joinsThisGroup groupRefs ann
      , Just ms <- traverse loopBindingOf bindings ->
          Array.concatMap
            ( \m ->
                [ { ref: TcoLocal (Just m.ident) lvl
                  , params: NEA.toArray m.params
                  , body: m.body
                  , wrapper: Nothing
                  }
                ] <> go m.body
            )
            (NEA.toArray ms)
            <> go rest
      | isLoopAnalysis ann -> []
      | otherwise -> go rest

    Branch pairs def -> foldMap (\(Pair _ body) -> go body) (NEA.toArray pairs) <> go def

    _ -> []

--------------------------------------------------------------------------------
-- Loop emission
--------------------------------------------------------------------------------

-- | Emit a loop group as statements: one `_ps_loopN` dispatch `function` plus one
-- | curried wrapper per ORIGINAL member, each driving an inline `while` over the
-- | tagged pair. This is `purejl`'s ADR-0003 shape, generalised twice over:
-- |
-- |   * with more than one branch a leading branch register selects which body to
-- |     run, so MUTUAL tail recursion trampolines; and
-- |   * join points are folded in as further branches, so a helper written in a
-- |     `where` NESTED inside a loop member becomes a jump rather than a call.
-- |
-- | No runtime support is needed for either — the `while` is the runtime.
genLoopGroup
  :: Env
  -> (Ident -> String)
  -> (Ident -> TcoRef)
  -> NonEmptyArray LoopBinding
  -> Gen (Array String)
genLoopGroup env nameOf refOf members = do
  let
    origs = map
      ( \m ->
          { ref: refOf m.ident
          , params: NEA.toArray m.params
          , body: m.body
          , wrapper: Just m.ident
          }
      )
      (NEA.toArray members)
  let groupRefs = map _.ref origs
  let joins = Array.concatMap (collectJoins groupRefs <<< _.body) origs
  let allMembers = origs <> joins
  let branching = Array.length allMembers > 1

  -- One slot per distinct local any branch binds: every member's parameters,
  -- plus the free variables the join points captured from the member bodies they
  -- were lifted out of.
  --
  -- The level filter is what keeps the register file small and, more
  -- importantly, correct. The dispatch function is emitted lexically INSIDE the
  -- scope that encloses the group, so anything bound further out is already
  -- captured by ordinary closure capture and must NOT be shadowed by a register
  -- (`tco3`'s `g` reads `y0` and `j` from two scopes up). Only locals bound at or
  -- inside the member bodies have to travel.
  let memberParams = Array.concatMap _.params allMembers
  let threshold = Array.foldl (\acc (Tuple _ (Level n)) -> min acc n) top memberParams
  let joinRefs = map _.ref joins
  let
    captured = Array.filter
      ( \r@(Tuple mbId (Level n)) ->
          n >= threshold
            && not (Array.elem r memberParams)
            && not (Array.elem (TcoLocal mbId (Level n)) groupRefs)
            && not (Array.elem (TcoLocal mbId (Level n)) joinRefs)
      )
      (Set.toUnfoldable (foldMap (freeLocals <<< _.body) joins))
  let layout = Array.nub (memberParams <> captured)

  -- The tag must be unique across the whole MODULE, not merely within a scope:
  -- the dispatch function is a named `function`, and two loop groups whose first
  -- parameter shares a de Bruijn level would otherwise both be `_ps_loop0` and
  -- the second would redefine the first. The fresh counter is module-wide.
  tag <- freshName ""
  let loopName = genPrefix <> "loop" <> tag
  let
    argNames = map (\i -> genPrefix <> "a" <> tag <> "_" <> show i)
      (Array.range 0 (max 1 (Array.length layout) - 1))
  let
    ctx =
      { members: map (\m -> { ref: m.ref, arity: Array.length m.params, params: m.params }) allMembers
      , layout
      , argNames
      , branching
      }
  let branchName = genPrefix <> "br" <> tag
  let resName = genPrefix <> "r" <> tag

  bodies <- traverse (memberBlock env ctx branchName branching) (Array.mapWithIndex Tuple allMembers)
  let
    dispatch =
      [ "function " <> loopName <> "(" <> commaSep ((if branching then [ branchName ] else []) <> argNames) <> ")" ]
        <> indent (Array.concat bodies)
        <> [ "end" ]

  -- One curried wrapper per ORIGINAL member, entering the loop with its branch
  -- index. Join points get none: they are not values, only jump targets.
  let
    wrappers = Array.mapMaybe
      ( \(Tuple idx m) -> do
          ident <- m.wrapper
          let ps = map localNameOf m.params
          -- At the wrapper only this member's own parameters are in scope; every
          -- other slot starts empty. Safe because a slot no branch has written is
          -- a join point's captured variable, and no join point has run yet.
          let entry = (if branching then [ show idx ] else []) <> slotArgs ctx idx ps []
          let
            drive =
              "begin " <> resName <> " = (1, (" <> commaSep entry <> ",)); "
                <> "while "
                <> resName
                <> "[1] == 1; "
                <> resName
                <> " = "
                <> loopName
                <> "("
                <> resName
                <> "[2]...); end; "
                <> resName
                <> "[2] end"
          pure (nameOf ident <> " = " <> lambdaChain ps drive)
      )
      (Array.mapWithIndex Tuple allMembers)

  pure (dispatch <> wrappers)

-- | The full register tuple for a jump to member `idx`: that member's parameters
-- | take their argument expressions, and every other slot carries its local
-- | through unchanged.
-- |
-- | `inScope` names the locals the jump site can actually read. Inside a branch
-- | that is every slot (each branch binds the whole layout on entry), so nothing
-- | is lost; at a wrapper it is only that member's parameters, and the rest start
-- | as `nothing`.
slotArgs :: LoopCtx -> Int -> Array String -> Array LocalRef -> Array String
slotArgs ctx idx args inScope = map slotFor ctx.layout
  where
  targetParams = maybe [] _.params (Array.index ctx.members idx)
  slotFor loc = case Array.elemIndex loc targetParams of
    Just i -> fromMaybe "nothing" (Array.index args i)
    Nothing
      | Array.elem loc inScope -> localNameOf loc
      | otherwise -> "nothing"

-- | One branch inside the dispatch function: bind the WHOLE register file, then
-- | walk the body in tail-aware statement mode.
-- |
-- | Binding every slot rather than only this branch's parameters is deliberate.
-- | It costs a few dead assignments and buys the invariant the join machinery
-- | rests on: every slot is in scope in every branch, so any jump can pass every
-- | slot on, and a captured variable survives an arbitrary chain of jumps.
memberBlock :: Env -> LoopCtx -> String -> Boolean -> Tuple Int GroupMember -> Gen (Array String)
memberBlock env ctx branchName branching (Tuple idx m) = do
  let
    binds = Array.mapWithIndex
      (\i loc -> localNameOf loc <> " = " <> fromMaybe "nothing" (Array.index ctx.argNames i))
      ctx.layout
  body <- genLoopStmts env ctx ctx.layout m.body
  let stmts = binds <> body
  pure
    if branching then [ "if " <> branchName <> " == " <> show idx ] <> indent stmts <> [ "end" ]
    else stmts

-- | Tail-aware statement walk of a loop body. A tail call to a branch of this
-- | group becomes `return (1, (registers...))` -- the continue signal the `while`
-- | reads -- and every other tail position becomes `return (0, value)`.
-- |
-- | `inScope` grows as the walk passes binders, and is what a jump reads to fill
-- | the slots it is not supplying arguments for.
-- |
-- | Bindings use `let ... end` rather than bare assignment: `return` inside a
-- | `let` still returns from the enclosing `function`, and the block keeps each
-- | IR scope a real Julia scope, so two sibling `Let`s that both open at the same
-- | de Bruijn level cannot collide. That is the hazard the Python lane had to
-- | close with a module-wide rename pass.
genLoopStmts :: Env -> LoopCtx -> Array LocalRef -> TcoExpr -> Gen (Array String)
genLoopStmts env ctx inScope te@(TcoExpr _ syn) = case syn of
  Branch pairs def -> genLoopBranch env ctx inScope (NEA.toArray pairs) def

  -- A join point's binding is NOT emitted: it has become a branch of this
  -- dispatch group, and every reference to it is a jump. The analysis guarantees
  -- there is no other kind of reference -- `joins` requires every use to be a
  -- saturated tail call.
  Let mbId lvl val rest
    | Array.elem (TcoLocal mbId lvl) (map _.ref ctx.members)
    , TcoExpr _ (Abs _ _) <- val -> genLoopStmts env ctx inScope rest
    | otherwise -> do
        v <- genExpr env val
        inner <- genLoopStmts env ctx (Array.snoc inScope (Tuple mbId lvl)) rest
        pure ([ "let " <> localName mbId lvl <> " = " <> v ] <> indent inner <> [ "end" ])

  LetRec lvl bindings rest
    | Array.all (\(Tuple ident _) -> Array.elem (TcoLocal (Just ident) lvl) (map _.ref ctx.members))
        (NEA.toArray bindings) -> genLoopStmts env ctx inScope rest

  App (TcoExpr _ hsyn) args
    | Just idx <- findMember ctx hsyn (NEA.length args) -> do
        as <- traverse (genExpr env) (NEA.toArray args)
        let entry = (if ctx.branching then [ show idx ] else []) <> slotArgs ctx idx as inScope
        pure [ "return (1, (" <> commaSep entry <> ",))" ]

  _ -> do
    e <- genExpr env te
    pure [ "return (0, " <> e <> ")" ]

-- | Every arm of a loop branch ends in a `return`, so the arms can be emitted as
-- | a flat run of `if` blocks with the default falling through -- no `else`
-- | nesting, and so no growth with the number of alternatives.
genLoopBranch :: Env -> LoopCtx -> Array LocalRef -> Array (Pair TcoExpr) -> TcoExpr -> Gen (Array String)
genLoopBranch env ctx inScope pairs def = case Array.uncons pairs of
  Nothing -> genLoopStmts env ctx inScope def
  Just { head: Pair cond body, tail } -> do
    c <- genExpr env cond
    stmts <- genLoopStmts env ctx inScope body
    rest <- genLoopBranch env ctx inScope tail def
    pure ([ "if " <> c ] <> indent stmts <> [ "end" ] <> rest)

findMember :: LoopCtx -> BackendSyntax TcoExpr -> Int -> Maybe Int
findMember ctx hsyn nargs =
  Array.findIndex (\m -> m.arity == nargs && matchesRef m.ref hsyn) ctx.members

matchesRef :: TcoRef -> BackendSyntax TcoExpr -> Boolean
matchesRef ref syn = case ref of
  TcoTopLevel q -> case syn of
    Var q2 -> q == q2
    _ -> false
  TcoLocal mbId lvl -> case syn of
    Local mbId2 lvl2 -> mbId == mbId2 && lvl == lvl2
    _ -> false

isLoopAnalysis :: TcoAnalysis -> Boolean
isLoopAnalysis (TcoAnalysis a) = a.role.isLoop

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

-- | @Data.Array@ -> @Data_Array@, with the four names Julia already owns pushed
-- | out of the way. Matches `purejl`'s `jlModuleName` -- it has to, since both
-- | lanes `include` the same generated foreign files.
jlModuleName :: ModuleName -> String
jlModuleName (ModuleName mn) =
  let base = String.replaceAll (String.Pattern ".") (String.Replacement "_") mn
  in if Array.elem base [ "Main", "Base", "Core", "PurejlRuntime" ] then base <> "_" else base

jlFileName :: ModuleName -> String
jlFileName mn = jlModuleName mn <> ".jl"

jlForeignFileName :: ModuleName -> String
jlForeignFileName mn = jlModuleName mn <> "_foreign.jl"

-- | The reserved prefix separating the MODULE namespace from the user-value
-- | namespace. Julia has one namespace per module, so a user binding could
-- | otherwise rebind an imported module outright -- `tests/purs/passing/4174`
-- | does exactly that, and Julia rejects it with "cannot assign a value to
-- | imported variable". `jlIdent` escapes any identifier that would land here,
-- | making the two provably disjoint. (Identical to `purejl`'s scheme, and
-- | necessarily so.)
moduleAliasPrefix :: String
moduleAliasPrefix = "_psmod_"

-- | The prefix on every name this codegen invents -- locals, temporaries, loop
-- | dispatchers, registers.
-- |
-- | It exists for the same reason `moduleAliasPrefix` does. A local named from
-- | its de Bruijn level is `_ps_v3_x`, and nothing stops a PureScript module from
-- | having a top-level binding *called* `_ps_v3_x`: the local would shadow it,
-- | and any reference to the top-level one from inside that scope would silently
-- | read the local. `jlIdent` pushes any user identifier out of this namespace,
-- | so the two are provably disjoint rather than merely unlikely to meet.
-- |
-- | This is the one place the name scheme departs from `purejl`'s
-- | `identToJlName`, and it is safe to depart: the only names that must agree
-- | across the two lanes are the FOREIGN ones, which are ordinary library
-- | identifiers and never begin `_ps_`.
genPrefix :: String
genPrefix = "_ps_"

jlModuleAlias :: ModuleName -> String
jlModuleAlias mn = moduleAliasPrefix <> jlModuleName mn

-- | Mangle a PureScript identifier to a Julia one, matching `purejl`'s
-- | `identToJlName` -- the foreign shims are named by it, so any drift here is an
-- | UndefVarError or, worse, a silent miss.
jlIdent :: Ident -> String
jlIdent (Ident s) =
  let
    name = mangle s
  in
    if isJuliaReserved name then name <> "_"
    else escapeReserved moduleAliasPrefix (escapeReserved genPrefix name)

-- | Push an identifier out of a reserved prefix by doubling the separator:
-- | `_ps_x` becomes `_ps__x`, which no generated name can be.
escapeReserved :: String -> String -> String
escapeReserved prefix name =
  if String.take (String.length prefix) name == prefix then
    prefix <> "_" <> String.drop (String.length prefix) name
  else name

mangle :: String -> String
mangle s = case Array.uncons (SCU.toCharArray s) of
  Nothing -> s
  Just { head, tail } -> first head <> foldMap replaceChar tail
  where
  first c
    | isAlpha c || c == '_' = SCU.singleton c
    | otherwise = "_" <> replaceChar c
  replaceChar c = case c of
    '.' -> "_"
    '$' -> "_dollar_"
    '\'' -> "\x2032" -- PRIME: a legal Julia identifier character
    '-' -> "_"
    _ | isValidJuliaChar c -> SCU.singleton c
    _ -> "_u" <> hex4 c

isAlpha :: Char -> Boolean
isAlpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

isDigit :: Char -> Boolean
isDigit c = c >= '0' && c <= '9'

isValidJuliaChar :: Char -> Boolean
isValidJuliaChar c = isAlpha c || isDigit c || c == '_' || c == '\x2032'

hex4 :: Char -> String
hex4 c =
  let h = toStringAs hexadecimal (toCharCode c)
  in String.drop (String.length h) "0000" <> h

-- | Julia keywords, contextual keywords, and per-module auto-bindings that
-- | cannot be assigned. Copied from `purejl`'s list; the two must agree.
isJuliaReserved :: String -> Boolean
isJuliaReserved name = Array.elem name
  [ "begin", "while", "if", "for", "try", "return"
  , "break", "continue", "function", "macro", "quote"
  , "let", "local", "global", "const", "do"
  , "struct", "module", "baremodule"
  , "using", "import", "export", "public"
  , "end", "else", "elseif", "catch", "finally"
  , "true", "false"
  , "abstract", "mutable", "primitive", "type"
  , "where", "in", "isa", "outer", "as"
  , "nothing", "missing", "include", "eval"
  , "Main", "Base", "Core"
  ]

-- | A local binder named from its de Bruijn level (the optimizer guarantees
-- | uniqueness within a scope), with the source name appended for readability.
-- |
-- | Unlike `backend-py` there is no rename pass and no `Env.locals` map: every
-- | binder here introduces a real Julia scope (`let`, a lambda parameter, or a
-- | `function` parameter), so the optimizer's within-a-scope uniqueness is
-- | exactly the guarantee the target needs.
localName :: Maybe Ident -> Level -> String
localName mbIdent (Level n) = case mbIdent of
  Just (Ident s) -> genPrefix <> "v" <> show n <> "_" <> foldMap keep (SCU.toCharArray s)
  Nothing -> genPrefix <> "v" <> show n
  where
  keep c = if isAlpha c || isDigit c then SCU.singleton c else ""

--------------------------------------------------------------------------------
-- Expressions
--------------------------------------------------------------------------------

genExpr :: Env -> TcoExpr -> Gen String
genExpr env (TcoExpr ann syn) = case syn of
  Var qi -> genRef env qi

  Local mbIdent lvl -> pure (localName mbIdent lvl)

  Lit lit -> genLit env lit

  -- Curried spine: `(f)(a)(b)`. Left-associative juxtaposition, so this stays
  -- flat rather than nesting one paren level per argument.
  App f args -> do
    fs <- genExpr env f
    as <- traverse (genExpr env) (NEA.toArray args)
    pure ("(" <> fs <> ")" <> foldMap (\a -> "(" <> a <> ")") as)

  Abs params body -> do
    e <- genExpr env body
    pure (lambdaChain (map (\(Tuple mbId lvl) -> localName mbId lvl) (NEA.toArray params)) e)

  UncurriedAbs params body -> do
    e <- genExpr env body
    pure ("((" <> commaSep (map (\(Tuple mbId lvl) -> localName mbId lvl) params) <> ") -> " <> e <> ")")

  -- Calling an uncurried EFFECT function runs its effect, so the body is walked
  -- in effect mode rather than built as a thunk and immediately forced.
  UncurriedEffectAbs params body -> do
    e <- genEffect env body
    pure ("((" <> commaSep (map (\(Tuple mbId lvl) -> localName mbId lvl) params) <> ") -> " <> e <> ")")

  UncurriedApp f args -> do
    fs <- genExpr env f
    as <- traverse (genExpr env) args
    pure ("(" <> fs <> ")(" <> commaSep as <> ")")

  -- Yields an `Effect a`, so the call is deferred into a thunk.
  UncurriedEffectApp f args -> do
    fs <- genExpr env f
    as <- traverse (genExpr env) args
    pure ("(() -> (" <> fs <> ")(" <> commaSep as <> "))")

  Accessor a acc -> do
    b <- genExpr env a
    pure (genAccessor b acc)

  Update base props -> do
    b <- genExpr env base
    ps <- traverse (\(Prop k v) -> (\s -> jlStr k <> " => " <> s) <$> genExpr env v) props
    pure ("Base.merge(" <> b <> ", Dict{String,Any}(" <> commaSep ps <> "))")

  -- Tag-tuple: tag at index 1, fields from index 2.
  CtorSaturated _ _ _ (Ident tag) fields -> do
    fs <- traverse (genExpr env <<< snd) fields
    pure (tupleLit (Array.cons (jlStr tag) fs))

  CtorDef _ _ (Ident tag) fieldNames -> do
    let names = map (\f -> genPrefix <> "f_" <> mangle f) fieldNames
    pure
      if Array.null names then tupleLit [ jlStr tag ]
      else lambdaChain names (tupleLit (Array.cons (jlStr tag) names))

  -- A local recursive group the optimizer marked `isLoop` (the `where go = ...`
  -- idiom, and local mutual recursion). The dispatch `function` and the wrappers
  -- are statements, so they go inside a `let` block whose value is the body.
  LetRec lvl bindings body
    | isLoopAnalysis ann
    , Just members <- traverse loopBindingOf bindings -> do
        stmts <- genLoopGroup env (\ident -> localName (Just ident) lvl) (\ident -> TcoLocal (Just ident) lvl) members
        b <- genExpr env body
        pure (letBlock stmts b)

  -- Ordinary local recursive group. The members are `let`-bound up front so
  -- forward references resolve: Julia closures capture the variable, not its
  -- value, so a member assigned later is visible to one built earlier.
  LetRec lvl bindings body -> do
    let names = map (\(Tuple ident _) -> localName (Just ident) lvl) (NEA.toArray bindings)
    assigns <- traverse
      (\(Tuple ident e) -> (\v -> localName (Just ident) lvl <> " = " <> v) <$> genExpr env e)
      (NEA.toArray bindings)
    b <- genExpr env body
    pure
      ( "let " <> commaSep (map (_ <> " = nothing") names) <> "; "
          <> String.joinWith "; " assigns
          <> "; "
          <> b
          <> " end"
      )

  Let mbIdent lvl val body -> do
    v <- genExpr env val
    b <- genExpr env body
    pure ("let " <> localName mbIdent lvl <> " = " <> v <> "; " <> b <> " end")

  -- An `Effect a` VALUE is a thunk; building one means deferring the whole
  -- effect block into a single zero-argument closure.
  EffectBind _ _ _ _ -> thunkOf (genEffect env (TcoExpr ann syn))

  EffectPure _ -> thunkOf (genEffect env (TcoExpr ann syn))

  EffectDefer a -> genExpr env a

  -- `if`/`elseif`/`else` is an expression in Julia, so a `case` with N
  -- alternatives is one flat chain rather than N nested conditionals.
  Branch pairs def -> do
    arms <- traverse
      (\(Pair cond body) -> Tuple <$> genExpr env cond <*> genExpr env body)
      (NEA.toArray pairs)
    d <- genExpr env def
    pure (ifChain arms d)

  PrimOp op -> genOp env op

  PrimEffect _ -> thunkOf (genEffect env (TcoExpr ann syn))

  PrimUndefined -> pure "nothing"

  Fail _ -> pure ("Base.error(\"Pattern match failed in module " <> escapeStr (unwrap env.currentModule) <> "\")")

-- | A reference to a top-level binding. Bindings in `lazyIdents` are
-- | `_runtime_lazy` thunks and are forced here; everything else -- including
-- | every FOREIGN value, which the shared shims define as a plain value -- is
-- | referenced directly.
genRef :: Env -> Qualified Ident -> Gen String
genRef env (Qualified (Just mn) ident) = do
  let forced = if Set.member (Qualified (Just mn) ident) env.lazyIdents then "()" else ""
  if mn == env.currentModule then pure (jlIdent ident <> forced)
  else do
    noteModule mn
    pure (jlModuleAlias mn <> "." <> jlIdent ident <> forced)
genRef _ (Qualified Nothing ident) = pure (jlIdent ident)

-- | `((a) -> ((b) -> e))`. Always parenthesised: a bare `->` body extends as far
-- | right as it can and would swallow a following call.
lambdaChain :: Array String -> String -> String
lambdaChain params e = Array.foldr (\p acc -> "((" <> p <> ") -> " <> acc <> ")") e params

-- | A `let` block wrapping statements around a value expression. `let` is both a
-- | scope and an expression, which is what lets statement-shaped output (a loop
-- | dispatcher, say) appear in an expression position without an IIFE.
letBlock :: Array String -> String -> String
letBlock stmts value =
  "let\n" <> String.joinWith "\n" (indent (stmts <> [ value ])) <> "\nend"

-- | `if c1; e1; elseif c2; e2; else; d; end` -- an expression, evaluating to the
-- | selected arm. The `else` is mandatory: without it a Julia `if` yields
-- | `nothing` when no arm matches, which would silently swallow a `Fail`.
ifChain :: Array (Tuple String String) -> String -> String
ifChain arms def = case Array.uncons arms of
  Nothing -> def
  Just { head: Tuple c e, tail } ->
    "(if " <> c <> "; " <> e <> rest tail <> " else; " <> def <> " end)"
  where
  rest as = case Array.uncons as of
    Nothing -> ""
    Just { head: Tuple c e, tail } -> "; elseif " <> c <> "; " <> e <> rest tail

-- | Defer a computation into an `Effect` (a zero-argument closure).
thunkOf :: Gen String -> Gen String
thunkOf g = (\e -> "(() -> " <> e <> ")") <$> g

--------------------------------------------------------------------------------
-- Literals, accessors, operators, effects
--------------------------------------------------------------------------------

genLit :: Env -> Literal TcoExpr -> Gen String
genLit env = case _ of
  LitInt n -> pure (parenNeg (show n))
  LitNumber n
    | Number.isNaN n -> pure "Base.NaN"
    | not (Number.isFinite n) -> pure (if n < 0.0 then "(-Base.Inf)" else "Base.Inf")
    | otherwise -> pure (parenNeg (floatLit (show n)))
  LitString s -> pure (jlStr s)
  LitChar c -> pure (jlChar c)
  LitBoolean b -> pure (if b then "true" else "false")
  LitArray as -> do
    xs <- traverse (genExpr env) as
    pure ("Any[" <> commaSep xs <> "]")
  LitRecord props -> do
    ps <- traverse (\(Prop k v) -> (\s -> jlStr k <> " => " <> s) <$> genExpr env v) props
    pure ("Dict{String,Any}(" <> commaSep ps <> ")")
  where
  parenNeg s = if String.take 1 s == "-" then "(" <> s <> ")" else s
  -- A `Number` must stay `Float64`. PureScript's `show` renders an integral
  -- double with a trailing `.0`, but not in exponent form (`1e21`), and a bare
  -- `1e21` is already Float64 in Julia -- so the guard is only for the digits-
  -- only case, which would otherwise land as an `Int64`.
  floatLit s =
    if String.contains (String.Pattern ".") s || String.contains (String.Pattern "e") s
      || String.contains (String.Pattern "E") s then s
    else s <> ".0"

genAccessor :: String -> BackendAccessor -> String
genAccessor base = case _ of
  GetProp k -> "(" <> base <> ")[" <> jlStr k <> "]"
  -- Array positions from the IR are 0-based (the PureScript API's convention);
  -- Julia indexes from 1.
  GetIndex i -> "(" <> base <> ")[" <> show (i + 1) <> "]"
  -- Field i of a tag-tuple lives at i+2; index 1 is the tag.
  GetCtorField _ _ _ _ _ idx -> "(" <> base <> ")[" <> show (idx + 2) <> "]"

genOp :: Env -> BackendOperator TcoExpr -> Gen String
genOp env = case _ of
  Op1 op a -> genOp1 op <$> genExpr env a
  Op2 op a b -> genOp2 op <$> genExpr env a <*> genExpr env b

genOp1 :: BackendOperator1 -> String -> String
genOp1 op a = case op of
  OpBooleanNot -> "(!(" <> a <> "))"
  -- Bit operations follow the shared `Data.Int.Bits` shims exactly: complement
  -- and the shifts wrap to int32, the logical operations do not. Ordinary Int
  -- arithmetic does NOT wrap -- Jurist's Int is Int64 (ADR-0001).
  OpIntBitNot -> "_int32(~(" <> a <> "))"
  OpIntNegate -> "(-(" <> a <> "))"
  OpNumberNegate -> "(-(" <> a <> "))"
  OpArrayLength -> "Base.length(" <> a <> ")"
  OpIsTag (Qualified _ (Ident tag)) -> "((" <> a <> ")[1] == " <> jlStr tag <> ")"

genOp2 :: BackendOperator2 -> String -> String -> String
genOp2 op a b = case op of
  OpArrayIndex -> "(" <> a <> ")[(" <> b <> ") + 1]"
  -- Julia's `&&`/`||` short-circuit and are expressions, so the shapes the
  -- optimizer relies on (`isTag Just x && p (field 0 x)`) work directly. The
  -- Python lane needed a guarded statement block here.
  OpBooleanAnd -> bin "&&"
  OpBooleanOr -> bin "||"
  OpBooleanOrd o -> cmp o
  OpCharOrd o -> cmp o
  OpIntOrd o -> cmp o
  OpNumberOrd o -> cmp o
  OpStringOrd o -> cmp o
  OpIntBitAnd -> bin "&"
  OpIntBitOr -> bin "|"
  OpIntBitXor -> "Base.xor(" <> a <> ", " <> b <> ")"
  OpIntBitShiftLeft -> "_int32((" <> a <> ") << ((" <> b <> ") & 31))"
  OpIntBitShiftRight -> "(_int32(" <> a <> ") >> ((" <> b <> ") & 31))"
  OpIntBitZeroFillShiftRight -> "_zshr(" <> a <> ", " <> b <> ")"
  -- Matches `Data_EuclideanRing_foreign`'s `intDiv`: floor division, zero on a
  -- zero divisor. The helper exists so the divisor is evaluated once.
  OpIntNum OpDivide -> "_int_div(" <> a <> ", " <> b <> ")"
  OpIntNum o -> bin (numOp o)
  -- Julia's Float64 `/` already yields ±Inf and NaN exactly as JS does, which is
  -- why -- unlike the Python lane -- this needs no helper.
  OpNumberNum o -> bin (numOp o)
  -- Julia concatenates strings with `*`.
  OpStringAppend -> bin "*"
  where
  bin o = "((" <> a <> ") " <> o <> " (" <> b <> "))"
  cmp o = bin (ordOp o)

ordOp :: BackendOperatorOrd -> String
ordOp = case _ of
  OpEq -> "=="
  OpNotEq -> "!="
  OpGt -> ">"
  OpGte -> ">="
  OpLt -> "<"
  OpLte -> "<="

numOp :: BackendOperatorNum -> String
numOp = case _ of
  OpAdd -> "+"
  OpSubtract -> "-"
  OpMultiply -> "*"
  OpDivide -> "/" -- Int is routed to _int_div above

-- | Run an effect NOW: build the expression that performs its steps in order and
-- | evaluates to its result.
-- |
-- | Treating each `EffectBind` as an ordinary expression would build the
-- | continuation as its own thunk and immediately force it -- correct, but one
-- | closure allocation per bind. Walking the chain in effect mode turns N nested
-- | thunks into N nested `let`s inside one, which is both cheaper and, because a
-- | `let` is a scope, still safe against name reuse.
-- |
-- | A `Ref` is a one-element `Any[]` vector, as in the shared `Effect.Ref` shim.
genEffect :: Env -> TcoExpr -> Gen String
genEffect env te@(TcoExpr _ syn) = case syn of
  EffectBind mbIdent lvl val body -> do
    v <- genEffect env val
    b <- genEffect env body
    pure ("let " <> localName mbIdent lvl <> " = " <> v <> "; " <> b <> " end")

  EffectPure a -> genExpr env a

  EffectDefer a -> genEffect env a

  -- A pure `Let` sequenced inside an effect block: a `let` either way.
  Let mbIdent lvl val body -> do
    v <- genExpr env val
    b <- genEffect env body
    pure ("let " <> localName mbIdent lvl <> " = " <> v <> "; " <> b <> " end")

  PrimEffect (EffectRefNew a) -> (\v -> "Any[" <> v <> "]") <$> genExpr env a

  PrimEffect (EffectRefRead a) -> (\v -> "(" <> v <> ")[1]") <$> genExpr env a

  PrimEffect (EffectRefWrite a b) -> do
    r <- genExpr env a
    v <- genExpr env b
    pure ("begin (" <> r <> ")[1] = " <> v <> "; nothing end")

  -- Anything else evaluates to an `Effect a` value, which is a thunk: force it.
  _ -> do
    e <- genExpr env te
    pure ("(" <> e <> ")()")

--------------------------------------------------------------------------------
-- Emission helpers
--------------------------------------------------------------------------------

-- | A Julia tuple literal. The trailing comma is required: `("Nothing")` is a
-- | parenthesised string, `("Nothing",)` is the nullary constructor.
tupleLit :: Array String -> String
tupleLit xs = "(" <> commaSep xs <> ",)"

commaSep :: Array String -> String
commaSep = String.joinWith ", "

-- | A double-quoted Julia string literal. `$` MUST be escaped -- it is Julia's
-- | string interpolation sigil, and PureScript identifiers contain it routinely
-- | (`Show$Dict`), so an unescaped one is a compile error at best.
jlStr :: String -> String
jlStr s = "\"" <> escapeStr s <> "\""

escapeStr :: String -> String
escapeStr s = foldMap escapeChar (SCU.toCharArray s)
  where
  escapeChar c = case c of
    '"' -> "\\\""
    '\\' -> "\\\\"
    '$' -> "\\$"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    '\x8' -> "\\b"
    '\xc' -> "\\f"
    _ | toCharCode c < 0x20 -> "\\u" <> hex4 c
    _ -> SCU.singleton c

-- | A Julia `Char` literal. `Char` is a codepoint, so a PureScript `Char` (a
-- | UTF-16 code unit) maps directly except for lone surrogates, which Julia
-- | accepts as `\uXXXX`.
jlChar :: Char -> String
jlChar c = case c of
  '\'' -> "'\\''"
  '\\' -> "'\\\\'"
  '\n' -> "'\\n'"
  '\r' -> "'\\r'"
  '\t' -> "'\\t'"
  _ | toCharCode c < 0x20 || (toCharCode c >= 0xD800 && toCharCode c <= 0xDFFF) ->
        "'\\u" <> hex4 c <> "'"
  _ -> "'" <> SCU.singleton c <> "'"
