# purescript-julia

A PureScript backend that compiles to Julia.

Part of the *Julia numerics backend for Hylograph* effort (Marginalia
project 219): the long game is Julia compute leaves (DifferentialEquations.jl,
DynamicalSystems.jl, Catlab.jl, …) feeding Hylograph visualizations, with a
PureScript-defined contract at the boundary. This repo is the "thin skin"
realisation of that seam — a from-scratch CoreFn → Julia code generator,
sibling of `purescript-python-new`.

## Status

**Working** — Hello World and the core libraries (prelude, effect, console)
compile and run.

### Representation choices

| PureScript | Julia |
|---|---|
| Functions | curried unary closures; application is `(f)(x)(y)` |
| ADT values | tag-tuples: `("Just", x)`, nullary `("Nothing",)` — tag at `[1]`, fields from `[2]` |
| Newtypes | identity (no wrapper at runtime) |
| Typeclass dictionaries | `Dict{String,Any}` keyed by member name |
| Records | `Dict{String,Any}`; update via `merge` |
| Arrays | `Any[...]` vectors (1-based; FFI handles the 0-based PS API) |
| `Effect a` | zero-argument closure (thunk) |
| Char / String | Julia `Char` / `String` |
| Unit / undefined | `nothing` |
| Modules | one Julia `module` per PS module, loaded deps-first by `loader.jl` |

Top-level mutually-recursive value bindings go through a lazy-thunk runtime
(`purejl_runtime.jl`); local recursion just uses Julia's closure capture.

### Known v1 limitations

- **No trampoline yet**: Julia does not guarantee TCO, so deep
  mutual/non-self recursion can blow the stack. (Self-tail-calls are fine in
  many shapes; the trampoline is the next interesting piece of work.)
- Int is `Int64`, not wrapped to 32-bit JS semantics.
- Pattern-binding shadowing across fall-through alternatives (inherited
  from the Python backend's structure; rare).

## Usage

```bash
# Prerequisites: stack, purs 0.15.x, spago, julia
stack build

# In a PureScript project configured to emit CoreFn
# (spago.yaml: workspace.backend.cmd: "true"):
spago build
stack exec purejl -- output output-jl
julia output-jl/main.jl
```

The generated tree is flat: one `Module_Name.jl` per PS module, FFI shims as
`Module_Name_foreign.jl` (included *inside* the module so their definitions
land in its namespace), `purejl_runtime.jl`, `loader.jl` (topo-ordered
includes restricted to Main's transitive closure), and `main.jl`.

## FFI

A module with `foreign import`s needs a `Module_Name_foreign.jl` file.
Shims for the core libraries are generated automatically; project-specific
shims go in `ffi-jl/` next to your `spago.yaml` — they are copied into the
output last and win over the built-ins.

Conventions (mirroring the JS foreign modules):

```julia
# curried: chains of unary closures
concatString(s1) = s2 -> s1 * s2

# effects: zero-argument closures
log(s) = () -> (Base.println(s); nothing)
```

Qualify `Base.` for anything your shim *calls* if the module shadows it
(e.g. `log`, `error`, `read`, `write` are all PS foreign names).

## Test project

`test-project/` is the smallest end-to-end check:

```bash
cd test-project
spago build
stack exec purejl -- output output-jl   # (or the purejl binary on PATH)
julia output-jl/main.jl
# Hello from PureScript, via Julia!
```
