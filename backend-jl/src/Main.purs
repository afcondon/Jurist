-- | CLI for `backend-jl` -- the optimizer-consumer lane for Jurist.
-- |
-- | Reads the CoreFn `purs` emitted, runs `purescript-backend-optimizer` over it,
-- | and writes one Julia module per PureScript module into the output directory,
-- | alongside the `purejl_runtime.jl` and `<Module>_foreign.jl` files that
-- | `purejl` (the oracle lane) produces. Nothing here writes a runtime or a
-- | foreign shim: the two lanes share one copy of each, so they cannot drift
-- | apart.
-- |
-- | It also writes the two files Jurist's output tree needs and the Python lane
-- | had no counterpart for (ADR-0006): a `loader.jl` of topologically-ordered
-- | `include`s, and a `main.jl` entry point.
module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldMap, for_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Ref as Ref
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.FS.Perms as Perms
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as Process
import PureScript.Backend.Optimizer.Codegen.Julia (codegenModule, knownArities, jlFileName, jlForeignFileName, jlModuleAlias, jlModuleName, lazyIdentsOf, runtimeImport)
import PureScript.Backend.Optimizer.Codegen.Julia.Builder (basicBuildMain)
import PureScript.Backend.Optimizer.Convert (BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ident(..), ModuleName(..), Qualified(..))
import PureScript.Backend.Optimizer.Reachability (pruneModule, reachableFromEntry)
import PureScript.Backend.Optimizer.Semantics.Foreign (coreForeignSemantics)

type BuildArgs =
  { coreFnDir :: FilePath
  , outputDir :: FilePath
  , mainModule :: String
  }

argParser :: ArgParser BuildArgs
argParser =
  ArgParser.fromRecord
    { coreFnDir:
        ArgParser.argument [ "--corefn-dir" ]
          "Path to input directory containing corefn.json files (default ./output)."
          # ArgParser.default (Path.concat [ ".", "output" ])
    , outputDir:
        ArgParser.argument [ "--output-dir" ]
          "Path to output directory for Julia files (default ./output-jl-opt)."
          # ArgParser.default (Path.concat [ ".", "output-jl-opt" ])
    , mainModule:
        ArgParser.argument [ "--main" ]
          "Entry module whose `main :: Effect _` is run (default Main)."
          # ArgParser.default "Main"
    }
    <* ArgParser.flagHelp

main :: Effect Unit
main = do
  args <- Array.drop 2 <$> Process.argv
  case ArgParser.parseArgs "backend-jl" "PureScript Julia backend (optimizer IR)." argParser args of
    Left err -> Console.error (ArgParser.printArgError err)
    Right buildArgs -> launchAff_ (build buildArgs)

build :: BuildArgs -> Aff Unit
build args = do
  -- Accumulate every built module, then prune from the entry point. Pruning
  -- needs the whole reference graph, so nothing can be emitted as we go.
  modulesRef <- liftEffect (Ref.new [])
  basicBuildMain
    { resolveCoreFnDirectory: pure args.coreFnDir
    , resolveExternalDirectives: pure Map.empty
    , analyzeCustom: \_ _ -> Nothing
    , foreignSemantics: coreForeignSemantics
    , onCodegenBefore: mkdirp args.outputDir
    , onPrepareModule: \_ coreFnMod -> pure coreFnMod
    , onCodegenModule: \_ _ backendMod _ ->
        liftEffect (Ref.modify_ (_ <> [ backendMod ]) modulesRef)
    , onCodegenAfter: do
        modules <- liftEffect (Ref.read modulesRef)
        let
          mainMn = ModuleName args.mainModule
          entry = Qualified (Just mainMn) (Ident "main")
          reachable = reachableFromEntry entry modules
          kept = Array.mapMaybe (keepModule reachable) modules
          -- Computed over the PRUNED modules, and over all of them, because the
          -- decision is per-definition while the reference can be anywhere.
          lazyIdents = foldMap lazyIdentsOf kept
          -- Saturated calls (ADR-0010), over the same pruned modules.
          arities = knownArities kept
          ordered = loadOrder kept
        for_ kept \backendMod -> do
          let text = renderModule { lazyIdents, arities } backendMod
          FS.writeTextFile UTF8 (Path.concat [ args.outputDir, jlFileName backendMod.name ]) text
        FS.writeTextFile UTF8 (Path.concat [ args.outputDir, "loader.jl" ]) (renderLoader ordered)
        FS.writeTextFile UTF8 (Path.concat [ args.outputDir, "main.jl" ])
          (renderEntrypoint lazyIdents mainMn)
    , traceIdents: Set.empty
    }

-- | Keep a module if entry reachability left it any binding, OR if any of its
-- | FOREIGN idents is reachable. The second case is not hypothetical: foreigns
-- | are not bindings, so they create no node in the reachability graph, and a
-- | module contributing only foreigns would otherwise be dropped out from under
-- | a live `_psmod_M.someForeign` reference.
keepModule :: Set (Qualified Ident) -> BackendModule -> Maybe BackendModule
keepModule reachable backendMod =
  case pruneModule reachable backendMod of
    Just pruned -> Just pruned
    Nothing
      | foreignReachable -> Just (backendMod { bindings = [] })
      | otherwise -> Nothing
  where
  foreignReachable = Array.any
    (\ident -> Set.member (Qualified (Just backendMod.name) ident) reachable)
    (Set.toUnfoldable backendMod.foreign)

-- | Dependencies-first order over the KEPT modules, which is what `loader.jl`'s
-- | `include`s need: a module's top-level bindings run at `include` time, so a
-- | dependency that has not been loaded is an `UndefVarError`.
-- |
-- | `imports` is used rather than the codegen's `used` set because it is the
-- | safe superset -- and it is intersected with the kept set, since pruning has
-- | already deleted some of what it names. PureScript forbids import cycles, so
-- | the DFS needs no cycle handling beyond the visited set.
loadOrder :: Array BackendModule -> Array ModuleName
loadOrder kept = _.acc (Array.foldl visit { seen: Set.empty, acc: [] } roots)
  where
  keptNames = Set.fromFoldable (map _.name kept)
  deps :: Map ModuleName (Array ModuleName)
  deps = Map.fromFoldable
    ( map
        ( \m -> Tuple m.name
            (Array.filter (\d -> d /= m.name && Set.member d keptNames) (Set.toUnfoldable m.imports))
        )
        kept
    )
  roots = map _.name kept
  visit st mn
    | Set.member mn st.seen = st
    | otherwise =
        let
          st' = Array.foldl visit (st { seen = Set.insert mn st.seen })
            (fromMaybe [] (Map.lookup mn deps))
        in
          st' { acc = Array.snoc st'.acc mn }

renderModule :: { lazyIdents :: Set (Qualified Ident), arities :: Map (Qualified Ident) Int } -> BackendModule -> String
renderModule { lazyIdents, arities } backendMod =
  String.joinWith "\n" (header <> [ "" ] <> out.lines <> [ "", "end", "" ])
  where
  out = codegenModule { currentModule: backendMod.name, lazyIdents, arities } backendMod

  header =
    [ "# Generated by backend-jl (optimizer IR) from PureScript module: " <> unModuleName backendMod.name
    , "# Do not edit this file directly."
    , "module " <> jlModuleName backendMod.name
    , runtimeImport
    ]
      <> importLines
      <> foreignLines

  -- `..M` is a sibling of this module in Julia's own `Main`, which is where
  -- `loader.jl` includes everything.
  importLines =
    map (\mn -> "import .." <> jlModuleName mn <> " as " <> jlModuleAlias mn)
      (Set.toUnfoldable out.used)

  -- The shim is `include`d INSIDE the module so its definitions land in this
  -- module's scope -- which is also why the runtime import above has to name
  -- `_js_number_string`, a function only the shims call.
  foreignLines =
    if Set.isEmpty backendMod.foreign then []
    else [ "include(\"" <> jlForeignFileName backendMod.name <> "\")" ]

renderLoader :: Array ModuleName -> String
renderLoader ordered =
  String.joinWith "\n"
    ( [ "# Generated by backend-jl - includes all modules in dependency order"
      , "include(\"purejl_runtime.jl\")"
      ]
        <> map (\mn -> "include(\"" <> jlFileName mn <> "\")") ordered
        <> [ "" ]
    )

-- | `main :: Effect Unit` is a thunk, so running the program is one extra call.
-- | The module is `Main_`, not `Main`: Julia's own top-level module already owns
-- | that name (Jurist ADR-0006).
renderEntrypoint :: Set (Qualified Ident) -> ModuleName -> String
renderEntrypoint lazyIdents mn =
  String.joinWith "\n"
    [ "# Entry point generated by backend-jl for module " <> unModuleName mn
    , "include(\"loader.jl\")"
    , jlModuleName mn <> ".main" <> forced <> "()"
    , ""
    ]
  where
  forced = if Set.member (Qualified (Just mn) (Ident "main")) lazyIdents then "()" else ""

unModuleName :: ModuleName -> String
unModuleName (ModuleName mn) = mn

mkdirp :: FilePath -> Aff Unit
mkdirp = flip FS.mkdir' { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
