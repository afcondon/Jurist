# purescript-julia

A PureScript backend that compiles to Julia.

Part of the *Julia numerics backend for Hylograph* effort (Marginalia
project 219): the long game is Julia compute leaves (DifferentialEquations.jl,
DynamicalSystems.jl, Catlab.jl, …) feeding Hylograph visualizations, with a
PureScript-defined contract at the boundary. This repo is the "thin skin"
realisation of that seam — a from-scratch CoreFn → Julia code generator,
sibling of `purescript-python-new`.

Family-level docs (the backend comparison table, instructions for adding
purerl/purepy/psgo columns to the differential matrix) live in the
polyglot site repo: `purescript-polyglot/docs/backends/`.

## Status

**Working** — Hello World and the core libraries compile and run. Built-in
FFI shims cover: prelude, effect, console, refs, partial, unsafe-coerce,
functions, **arrays** (incl. `Data.Array.ST`), **st**, **strings**
(CodeUnits / CodePoints / Common / Unsafe), **foldable-traversable**,
**integers** (incl. `Data.Int.Bits`), **numbers** (incl. `Data.Number.Format`),
**unfoldable**, **enums**, **control** (`Control.Extend`), and **records**
(`Record.Unsafe`, `Record.Builder`, `Record.Unsafe.Union`). `Data.String.Regex`
ships as a loud-failure stub (no real PCRE mapping yet).

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

### Tail-call optimization

Julia does not guarantee TCO, so — mirroring purs's own JS optimizer —
bindings whose self-references are all fully-saturated tail calls compile
to a dispatch loop:

```julia
sumTo = (function ();
    function _tco_loop(acc, n); ...; end;     # (1, newargs) | (0, result)
    (acc) -> (n) -> (begin; _tco_r = (1, (acc, n,));
        while _tco_r[1] == 1; _tco_r = _tco_loop(_tco_r[2]...); end;
        _tco_r[2]; end));
end)()
```

The function-call-per-iteration shape is deliberate: closures created in
the loop body capture per-iteration bindings (in-place param mutation
would box and share them). Applies at top level and to local `go` loops;
verified to 10⁸ iterations.

### Known v1 limitations

- Mutual recursion is not trampolined (matches the JS backend, where
  `MonadRec` is the idiom for unbounded non-self recursion).
- Int is `Int64`, not wrapped to 32-bit JS semantics (`Data.Int.Bits`
  and `Data.Int.pow` do apply JS `ToInt32` wrapping).
- `Data.String.CodeUnits` treats "code units" as codepoints (Julia
  `Char`s), not UTF-16 units — identical for BMP text, diverges on
  astral-plane characters.
- `localeCompare` is codepoint order, not locale-aware collation.
- `Data.Number.fromString` / `Data.Int.fromString` use Julia's
  `tryparse` rather than JS `parseFloat`/`parseInt` prefix-parsing
  (e.g. `"3.5abc"` is `Nothing` here, `Just 3.5` in JS).
- Pattern-binding shadowing across fall-through alternatives (inherited
  from the Python backend's structure; rare).

### Cross-backend portability: the Numbers/Math wrinkle

A *nice-to-have* of this work is "write the description once in
PureScript and run it on whichever backend you like" — develop and test a
numeric model on Node or the BEAM with a pure-PureScript denotation, then
deploy it to the Julia backend for the real compute. The Tier-2 eDSL
(`examples/numexpr-edsl`) demonstrates exactly this: one `SystemSpec`
description, the *same* `integratePure` running bit-identically on Julia,
Node, and the BEAM.

The one snag is in the standard library, not this backend: the
**transcendentals** (`sin`/`cos`/`exp`/`log`/`sqrt`/`pow`) live on
`Data.Number` in the modern JS package sets and in this backend's built-in
shims, but the **purerl** package set still strands them in the deprecated
`Math` module. So a module that uses them can't be *literally* the same
source across the JS/purejl sets and purerl without a thin shim. In
`examples/numexpr-edsl` the shared `core` package papers over this by
owning those six primitives as its only `foreign import`s, with a one-line
shim per backend (`Math.*` / `math:*` / `Base.*`).

This is an **acceptable MVP wrinkle**: the develop-anywhere story is a
convenience, not the point. The point is to show the PureScript community
things *only* the Julia runtime can do (symbolic Jacobians, stiff/DAE
solvers, Catlab, …). The strongest case for the wider PureScript backend
ecosystem to converge `Data.Number`/`Math` is to first put compelling
Julia-only demos in front of people — then "let's tidy this up" writes
itself.

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

## Testing

### Cross-backend differential suite — `test-suite/`

The headline claim: **the Julia backend produces byte-identical output to
the reference JS backend** across 400+ differential tests, modulo four
deliberate, documented divergences.

The suite compiles ten `Test.*` modules once with
`purs --codegen corefn,js`, runs each module on Node **and** on Julia
(via purejl), and diffs every `TEST <name>: <value>` line:

```bash
cd test-suite
python3 run_tests.py            # build both backends + compare
# 422/426 identical, 4 known divergences, 0 failures, 0 module errors
```

Coverage: ADTs and pattern matching (literal/array/record/nested
patterns, guards with fall-through, multi-scrutinee), the full
`Data.Array` surface including the ST-backed functions and sort
*stability*, strings (CodeUnits/CodePoints/Common incl. edge cases like
empty patterns and out-of-range indices), Int and Number semantics
(division families, bit ops with JS `ToInt32` wrapping, **JS
`Number.prototype.toString` formatting** including the 1e21 and 1e-7
notation boundaries), typeclass dictionary dispatch, Effect and ST
combinators, `Data.Function.Uncurried` round-trips, and recursion
(trampolined TCO at 10⁶ depth, closure capture inside loops, MonadRec).

The four known divergences are the documented representation choices:
two `ASTRAL-` tests (UTF-16 code units vs codepoints) and two `INT64-`
tests (JS wraps Int arithmetic to int32 — the JS values there are the
*overflowed* ones).

The suite has already paid for itself: it caught an inverted
length-tiebreak in `ordArrayImpl` (prefix-equal arrays compared
backwards — the PS caller re-inverts the foreign's sign convention).

### Smoke test — `test-project/`

The smallest end-to-end check (60 outputs):

```bash
cd test-project
spago build
stack exec purejl -- output output-jl   # (or the purejl binary on PATH)
julia output-jl/main.jl
# Hello from PureScript, via Julia!
```

### Compute-leaf example — `examples/lorenz-leaf/`

The thin-skin seam demo: PS contract + Julia RK4 numerics in a user
`ffi-jl/` shim + JSON at the boundary.
