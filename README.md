# Jurist — small typed languages for mathematical things

## **→ [The demo site](https://afcondon.github.io/Jurist/)** ←

Little languages for **dynamical systems, symbolic expressions, optimization
models, Petri nets, typed graphs** — backed by the Julia scientific ecosystem
as their production semantics. Each is a handful of PureScript types: cheap to
mint, one per domain, and a description that typechecks is a well-formed
object of that domain.

The [demo site](https://afcondon.github.io/Jurist/) shows ten examples, each
counterposing **the PureScript you write** with **what Julia computes from
it**: a Lorenz butterfly integrated bit-identically on three runtimes, a
double pendulum as the DAE it actually is, exact symbolic differentiation,
rigorously *proven* roots and optima, and Catlab's applied category theory
(functorial dynamics, homomorphism search, data migration).

In fact, Jurist isn't a minimal bridge to Julia — it's a **full backend for
the PureScript language** (`purejl`), peer to the JavaScript, Erlang, and
other backends, and built in the same way: a from-scratch CoreFn → Julia
code generator, sibling of Pythia (`purescript-python`). Part of the wider
*polyglot PureScript* effort: if a core tenet of FP is to "make illegal
states unrepresentable", polyglot-PureScript extends this across multiple
runtimes — your types should mean the same thing on the Erlang or Go backend
as they do in the browser.

---

Family-level docs (the backend comparison table, instructions for adding
purerl/purepy/psgo columns to the differential matrix) live in the
polyglot site repo: `afc-work/docs/backends/`.

## Status

**Working** — Hello World and the core libraries compile and run. Built-in
FFI shims cover: prelude, effect, console, refs, partial, unsafe-coerce,
functions, **arrays** (incl. `Data.Array.ST`), **st**, **strings**
(CodeUnits / CodePoints / Common / Unsafe), **foldable-traversable**,
**integers** (incl. `Data.Int.Bits`), **numbers** (incl. `Data.Number.Format`),
**unfoldable**, **enums**, **control** (`Control.Extend`), **records**
(`Record.Unsafe`, `Record.Builder`, `Record.Unsafe.Union`), **foreign-object**
and **argonaut-core** (an ordered object type, and a JSON printer and parser
that agree with `JSON.stringify` and `JSON.parse`;
[ADR-0011](docs/design-decisions/0011-foreign-object-and-json.md)). `Data.String.Regex`
ships as a loud-failure stub (no real PCRE mapping yet).

### Two implementations, on purpose

Since 2026-07-31 this repo holds **two** code generators
([ADR-0009](docs/design-decisions/0009-two-implementations.md)):

- **`purejl`** (`src/`, Haskell, raw CoreFn) — the correctness **oracle**.
  Every claim below rests on it.
- **`backend-jl`** (`backend-jl/`, PureScript) — a consumer of
  [`purescript-backend-optimizer`](https://github.com/aristanetworks/purescript-backend-optimizer)'s
  optimized IR, so TCO, inlining and dead-code elimination are tracked upstream
  rather than re-solved in three backends. It emits module bodies only: the
  runtime and every foreign shim come from `purejl` and are consumed
  unmodified, and `bin/conformance.sh` fails if a second copy ever appears.

Both lanes are diffed against the JavaScript backend over the same corpus,
not against each other
([ADR-0004](docs/design-decisions/0004-differential-conformance.md)). Two
independent paths through the compiler, each held to the same reference, is
what makes "conformant" a checkable claim rather than a hope.

### Representation choices

| PureScript | Julia |
|---|---|
| Functions | a function *value* is a curried unary closure, applied as `(f)(x)(y)`. A top-level function of known arity is also a method `_ps_sat_<name>(a, b, ..)`, and a call with enough arguments goes straight to it ([ADR-0010](docs/design-decisions/0010-saturated-calls-and-inliner.md)) |
| ADT values | one struct, `PSData`, for every constructor: tag at `[1]`, fields from `[2]`. Until October 2026 these were tag-tuples, `("Just", x)`; the indexing is unchanged, the type is not ([ADR-0001](docs/design-decisions/0001-runtime-representation.md), 2026-10 amendment) |
| Newtypes | identity (no wrapper at runtime) |
| Typeclass dictionaries | `Dict{String,Any}` keyed by member name |
| Records | `Dict{String,Any}`; update via `merge` |
| Arrays | `Any[...]` vectors (1-based; FFI handles the 0-based PS API) |
| `Effect a` | callable with zero arguments: a closure, or a `PSEff` box when built by `bind` |
| Char / String | Julia `Char` / `String` |
| Unit / undefined | `nothing` |
| Modules | one Julia `module` per PS module, loaded deps-first by `loader.jl` |

Top-level mutually-recursive value bindings go through a lazy-thunk runtime
(`purejl_runtime.jl`); local recursion just uses Julia's closure capture.

### Tail-call optimization

Julia does not guarantee TCO, so — mirroring purs's own JS optimizer —
bindings whose self-references are all fully-saturated tail calls compile
to a dispatch loop: a step function that returns either "go round again
with these arguments" or "done with this result", and a `while` that drives
it. [ADR-0003](docs/design-decisions/0003-tco-trampoline.md) shows the loop,
and [ADR-0010](docs/design-decisions/0010-saturated-calls-and-inliner.md)
how a top-level function now enters it from its saturated method.

The function-call-per-iteration shape is deliberate: closures created in
the loop body capture per-iteration bindings (in-place param mutation
would box and share them). Applies at top level and to local `go` loops.
The corpus exercises it at 10⁶ depth; no gate runs it deeper.

### Known v1 limitations

- Mutual recursion is not trampolined *by `purejl`* (matches the JS backend,
  where `MonadRec` is the idiom for unbounded non-self recursion). The
  `backend-jl` lane below does trampoline the direct case; what still escapes
  both is a join point — a member defined in a `where` nested inside another.
- Int is `Int64`, not wrapped to 32-bit JS semantics (`Data.Int.Bits`
  and `Data.Int.pow` do apply JS `ToInt32` wrapping).
- `Data.String.CodeUnits` treats "code units" as codepoints (Julia
  `Char`s), not UTF-16 units — identical for BMP text, diverges on
  astral-plane characters.
- `localeCompare` is codepoint order, not locale-aware collation.
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
Shims for the core libraries are generated automatically. A project's own
shim sits beside its `.purs` file, as `Foo.jl` next to `Foo.purs`, the way
purs finds a co-located `Foo.js`. An `ffi-jl/` directory next to
`spago.yaml` is the older layout and still works as a fallback. User shims
win over the built-ins.

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
the reference JS backend** over the shared `Test.*` corpus, except for a
finite, enumerated list of deliberate divergences.

The suite compiles every module under `test-suite/src/Test/` once with
`purs --codegen corefn,js`, runs each module on Node **and** on Julia
(via purejl), and diffs every line, `TEST <name>: <value>` or not:

```bash
cd test-suite
python3 run_tests.py            # build both backends + compare
```

**This README quotes no counts, on purpose.** They move with the corpus, and
figures quoted here have gone stale more than once. The last line the gate
prints is the claim: how many lines were identical, how many were ledgered,
and how many failed.

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

The deliberate divergences live in `test-suite/divergences.json`, the
ledger. Each entry records the JS value, this backend's value and a cause,
and a ledgered line passes only if both values are exactly the recorded
ones. A value that moves is a MISMATCH; an entry that is no longer needed is
STALE; both fail the run. The causes are:

- `INT32-WRAP`: JS wraps every Int operation to 32 bits, and Julia's `Int`
  is 64-bit, so the JS values are the overflowed ones.
- `ASTRAL`: JS counts UTF-16 code units; Julia counts code points. The two
  agree on text in the Basic Multilingual Plane.
- `REM-ZERO`: `Int.rem x 0` is `NaN` on JS, which is not an Int at all.
- `STACK`: JS captures a stack when an `Error` is constructed; Julia has one
  only once an exception is raised.

### And against the compiler's own test suite

That corpus is one **we wrote**, so it can only prove parity on cases someone
thought of. `purescript/purescript`'s `tests/purs/passing` is the suite the
compiler team wrote to *define the language*:

```
341/347 = 98.3%   tests/purs/passing @ v0.15.15   purejl      (the oracle)
342/347 = 98.6%   tests/purs/passing @ v0.15.15   backend-jl  (ADR-0009)
```

Both measured 2026-07-31, same day and same harness
(`purs-corpus/run_corpus.py`). Nothing gates on this corpus, so these two
lines are a dated measurement, not a standing claim. Most of the remaining causes are common to more
than one backend — they are in the shared model, not in this lowering. Full
analysis: `docs/kb/reference/purs-corpus-b4-results.md` in the `docs` repo.

The headline from first contact was **`CODEGEN_ERR` = 0**: across 364 tests
probing rank-N types, functional dependencies, instance chains, `Coercible`
and typelevel symbols, nothing made the code generator refuse or crash.

The suite has already paid for itself: it caught an inverted
length-tiebreak in `ordArrayImpl` (prefix-equal arrays compared
backwards — the PS caller re-inverts the foreign's sign convention).

### Smoke test — `test-project/`

The smallest end-to-end check. No gate runs it:

```bash
cd test-project
spago build
stack exec purejl -- output output-jl   # (or the purejl binary on PATH)
julia output-jl/main.jl
# Hello from PureScript, via Julia!
```

### The demo lane — `bin/demos.py`

Rebuilds every example and holds what it writes to the committed copy the
demo site draws from: exactly where the result is combinatorial, within a
stated tolerance where a solver produced the numbers. The examples' Julia
packages are pinned by committed `Manifest.toml` files. CI runs it.

```bash
bin/demos.py                 # every example
bin/demos.py petri-catlab    # one
```

### Glassbox on Julia — `examples/glassbox/`

[Glassbox](https://github.com/afcondon/purescript-glassbox)'s unmodified
core, compiled to Julia, regenerates its conformance vectors for every
machine; each file must be byte-identical to the one Node generated. This is
the family's claim on a real library: one typed model, the same answers on a
second runtime.

### Compute-leaf example — `examples/lorenz-leaf/`

The earliest example (June 2026), kept as a record: a PureScript contract
over an RK4 Lorenz integrator **written by hand in the foreign file**. That
is what the family's seam rule now forbids ("the FFI holds a call into a
foreign library, never your algorithm"), and it was written before the rule
was. `examples/numexpr-edsl` is the form to copy.

### The demo site — `site/`

A static gallery that **counterposes the PureScript eDSL you write against
what Julia computes from it** — input | output, side by side. The home page
(`site/index.html`) is **one long page with every example inlined** — few
people ever navigate a site fully — and is GENERATED: the standalone pages
(`lorenz.html`, `pendulum.html`, …) are the source of truth; edit those (or
`partials/` for the landing copy and colophon) and re-run
`python3 site/build-site.py`, which scopes each page's CSS, prefixes its DOM
ids, and IIFE-wraps its render script so ten sections coexist. Everything
opens from the filesystem with no server, though four pages load KaTeX from a
CDN. All data is committed as `window.*` script globals under `site/data/`,
copied from each example's `*-viz/` output, and the demo lane
(`bin/demos.py`) holds both copies to a fresh run of the example. The one
file it does not yet check is the Lorenz orbit, which is dumped by
`examples/numexpr-edsl/node/src/DumpOrbit.purs`, i.e. computed by
`integratePure` on Node. That page's receipts (maxZ on Node / BEAM /
Julia) are figures from a June 2026 run typed into the page. Design note:
`docs/jurist-demos-site.md`. The site deploys to GitHub Pages
(`.github/workflows/pages.yml`).
