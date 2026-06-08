# 0006. Module-per-module layout, topological loader, lazy-thunk runtime

- Status: Accepted
- Date: 2026-06-08

(Decision made when the backend was first built, 2026-06-05; this is a
backfill.)

## Context

A PureScript program is many modules forming an import DAG, and top-level value
bindings within and across modules may be mutually recursive or forward-
referencing. Julia needs (a) a deterministic load order, (b) namespace
hygiene between modules, and (c) a way to evaluate value-level recursion that
would otherwise be a use-before-definition error.

## Decision

- **One Julia `module` per PureScript module** (`Module_Name.jl`), giving each
  its own namespace. FFI shims are `include`d **inside** the module
  (`Module_Name_foreign.jl`) so their definitions land in the module's scope.
- A generated **`loader.jl`** with topologically-ordered `include`s, restricted
  to `Main`'s transitive closure, plus a `main.jl` entry point. The output tree
  is flat.
- Top-level **mutually-recursive / forward-referencing value bindings** go
  through a lazy-thunk runtime (`purejl_runtime.jl`, `_runtime_lazy`), with a
  "smart `Rec` partition" that only thunks the bindings that actually need it.
  Local recursion just uses Julia closure capture.

## Consequences

- Clean per-module namespaces; FFI names resolve in their owning module.
- The loader loads only `Main`'s reachable closure — dead modules are not
  emitted into the load order. **But** a `Main`-less entry (the differential
  suite runs each `Test.*` module directly) loads *everything*, so **every**
  foreign-bearing module in the set must have a shim present. This is why
  `Data.String.Regex` ships as a loud-failure stub rather than being absent:
  its file must exist for such loaders to link.
- Lazy thunks make value-level forward references and CAF-style recursion work
  without a separate ordering pass over value bindings.

## Alternatives considered

- **Single-file output.** Rejected: loses module boundaries and namespace
  hygiene, and makes FFI name resolution ambiguous.
- **Eager top-level evaluation in dependency order.** Rejected: cannot express
  mutually-recursive value bindings or forward references; the lazy-thunk
  runtime is what makes those well-defined.
- **Lean on Julia's package/precompilation machinery.** Out of scope for a code
  generator emitting a flat tree; `include`-based loading is simpler and has no
  packaging prerequisites.
