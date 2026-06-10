# numexpr-edsl — the Tier-2 eDSL (ADR-0007)

A typed PureScript eDSL that crosses the PureScript→Julia seam **once** as a
*description* and is denoted into Julia's numeric stack — the answer to the
`mapNum` callback anti-pattern (a PureScript closure per inner-loop evaluation
is slow and opaque to Julia's specializer).

The description is **backend-agnostic** and the denotations are separate, so the
*same* typed system runs on more than one runtime — "one description, many
denotations". The example is split into four spago workspaces plus a frontend:

```
numexpr-edsl/
  core/   numexpr-core — the backend-agnostic description + pure denotation.
          Data.NumExpr     (the precision ADT, eval, render)
          Data.SystemSpec  (row-typed ODE surface, `system`, + integratePure:
                            a pure-PureScript RK4 that runs on ANY backend)
  julia/  numexpr-edsl — the Julia (purejl) denotation. Depends on core, adds:
          Data.NumExpr.Julia    (JExpr builders, compile, evalBatch)
          Data.SystemSpec.Julia (native fused RGF + RK4 — Field/compileField/integrate)
          Data.MTKSystem        (ModelingToolkit: analytic Jacobian, stiff solve)
          Data.DAESystem        (index-1 DAEs: the double pendulum)
          ffi-jl/, julia-env/, bench/
  node/   numexpr-node — the Node/JS denotation. Depends only on core; runs
          integratePure on the stock JavaScript backend.
  beam/   numexpr-beam — the BEAM/Erlang denotation. Depends only on core; runs
          integratePure on the Erlang VM via purs-backend-erl.
  viz/    standalone Hylograph (HATS) frontend — a pure player of the DAE frames.
```

`core`'s only `foreign import`s are the **six transcendental math primitives**
(`numSin`, `numPow`, …) the reference interpreter needs — irreducible machine
math that every backend has under a different name, shimmed one line per backend
(`NumExpr.js` → `Math.*`, `NumExpr.erl` → `math:*`, and the purejl
`ffi-jl/Data_NumExpr_foreign.jl` → `Base.*`). Lorenz uses none of them, so the
pure orbit is identical across runtimes regardless. Everything else in `core` —
the ADT, the row machinery, `integratePure` — is pure PureScript. Each denotation
workspace depends on `core` by path (`workspace.extraPackages`), so the *same*
source resolves against each backend's package set (the JS registry set for
node/julia, the purerl `erl-0.15.3` set for beam).

> The purerl `numbers` package strands the transcendentals in the deprecated
> `Math` module rather than `Data.Number` (where the modern JS sets and purejl
> put them); the per-backend shim papers over that. Worth raising with the purerl
> maintainers once these demos ship.

The pure `integratePure` is the develop-anywhere denotation; the Julia modules are
the production denotation. They are cross-checked against each other and against
the Node and BEAM runs (same `lorenz`, maxZ ≈ 47.834 on all three pure runtimes).

## The increments

1. **`Data.NumExpr`** (core) / **`Data.NumExpr.Julia`** — a numeric-expression
   precision ADT with `Ring`/`Semiring` ergonomics (`num 10.0 * (var "y" - var
   "x") + sinE (var "z")`). The pure ADT + reference `eval`/`render` live in core;
   the Julia companion folds the ADT through handed-in Julia builders (the shim
   never destructures a PureScript ADT, per ADR-0002) and metaprograms it into a
   native `RuntimeGeneratedFunction`. The Julia-compiled function matches the pure
   interpreter **byte-for-byte**.

2. **`Data.SystemSpec`** (core) / **`Data.SystemSpec.Julia`** — a **row-typed**
   system of ODEs: state space and parameters are PureScript rows, so the RHS is
   written with typed field access (`s.x`, `p.sigma`; a misspelt `s.q` is a
   compile error). Two denotations of the *same* `lorenz`:
   - **`integratePure`** (core, no FFI) — a pure-PureScript RK4 that runs on
     Node, the BEAM, or purejl. The develop-anywhere prototype executor.
   - **`Data.SystemSpec.Julia.integrate`** (julia) — the vector field compiled to
     one fused native RGF and integrated by a native RK4. The production executor.

   Both reproduce the independent `examples/lorenz-leaf` (maxZ ≈ 47.834), and the
   two are byte-identical over 5000 steps (`integratePure` on Julia matched
   `integrate` exactly; the same source on Node lands in the same envelope).

3. **`Data.MTKSystem`** (julia) — the *same* `SystemSpec`, denoted into
   **ModelingToolkit** instead of a hand-rolled integrator. The equations become
   a symbolic `System`; `mtkcompile` simplifies it; MTK derives the **analytic
   Jacobian** (derivatives never written in PureScript); and SciML's default
   adaptive solver — a polyalgorithm that auto-switches to a stiff method when it
   detects stiffness — integrates it using that Jacobian. Demonstrates two things
   the fixed-step RK4 can't: the derived Jacobian, and a genuinely **stiff**
   system (Robertson) solved cleanly.

4. **`Data.DAESystem`** (julia) — a row-typed **differential-algebraic** system: a
   double pendulum in Cartesian coordinates. Beyond `state` and `params` it adds an
   `alg` row of *algebraic variables* (the rod tensions, no time derivative) and
   one closing *constraint* per algebraic variable — the constraint lambda
   returns a `Record alg`, so the type system pins exactly one constraint per
   tension (a well-posed index-1 DAE by construction). MTK denotes it, derives
   the constraints, and an **implicit stiff solver** (`Rodas5P`) holds the rigid
   rods to ~1e-8 through fully chaotic motion — something no plain ODE integrator,
   and no `scipy.solve_ivp` (no DAE/algebraic-variable support), can do. The
   trajectory is written to JSON and rendered by a Hylograph frontend (see
   `viz/`).

5. **`Data.Differentiate`** (julia) — the **differentiation round-trip**. Hand a
   `NumExpr` across the seam; Julia binds its variables to Symbolics scalars,
   differentiates symbolically, and hands the derivative **back as LaTeX**
   (`Latexify`) — the chain rule, fractions (`∂/∂x log x = 1/x`) and trig, derived
   and typeset, never written in PureScript. `Main` differentiates a showpiece
   expression and the Lorenz vector field (its analytic Jacobian), writing
   `derivatives.json` for a KaTeX page (`diff-viz/`). "Descriptions across,
   *descriptions back*" — what returns is math you can read.

The seam is identical across the Julia denotations (ADR-0007, "descriptions
across, handles back"): PureScript hands over a typed description; Julia owns the
computation; results return as handles (`Compiled`, `Field`, `MTKField`/`Solution`,
`DAEField`/`DAESolution`) and are materialised only on demand.

## Frontend (`diff-viz/`) — the typeset derivatives

After the Julia run writes `derivatives.json` (increment 5), a static KaTeX page
renders the expressions and their symbolic gradients at publication quality:

```bash
cp julia/derivatives.json diff-viz/        # the increment-5 output
cd diff-viz && python3 -m http.server 4179 # http://127.0.0.1:4179
```

## Build & run — Node (the develop-anywhere denotation)

No Julia required. From `node/`:

```bash
cd node
spago run
```

Expected: the Lorenz orbit integrated by `integratePure` on the JS backend,
`maxZ (pure-PS RK4, on Node): 47.833954…` (the Julia native RK4 reference is
47.834), and `attractor in chaotic envelope (40 < maxZ < 55): true`.

## Build & run — BEAM (the same denotation on Erlang)

The `beam/` workspace runs `integratePure` on the Erlang VM via
[`purs-backend-erl`](https://github.com/purerl/purescript) (stock `purs` →
CoreFn → Erlang). Needs Erlang/OTP + `rebar3`/`erlc` on PATH. From `beam/`:

```bash
cd beam
npm install                               # one-time: fetches purs-backend-erl
spago build                               # CoreFn in output/, .erl in output-erl/
mkdir -p ebin
find output-erl -name '*.erl' -exec erlc -disable-feature maybe_expr -o ebin {} +
erl -noshell -pa ebin -eval "(('main@ps':main()))()" -eval "init:stop()"
```

Expected: `maxZ (pure-PS RK4, on BEAM): 4.78339540885981975293e+01` — the *same*
IEEE-754 double as the Node run (Lorenz's RHS is pure +,−,×, so the three pure
runtimes agree bit-for-bit), in the chaotic envelope.

## Build & run — Julia (all four increments)

The Julia increments run under a **dedicated environment** in `julia/julia-env/`
(`Manifest.toml` is gitignored, so resolve it once). Increments 1 & 2 use the
lightweight `RuntimeGeneratedFunctions`; increment 3 adds ModelingToolkit. Run
everything **from `julia/`** so the shims in `ffi-jl/` are picked up:

```bash
cd julia

# one-time: resolve the MTK environment (heavy — pulls ~220 packages)
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'

# build the PureScript (compiles core too), emit CoreFn, generate Julia:
spago build
stack exec purejl -- output output-jl      # or: purejl output output-jl

# run with the MTK environment active so `using ModelingToolkit` resolves:
julia --project=julia-env output-jl/main.jl
```

Expected: increment 1 `staging faithful: true`; increment 2 Lorenz `maxZ
47.834` (both the native RK4 and the pure-PS cross-check); increment 3 the printed
simplified equations + analytic Jacobians, the MTK-solved Lorenz `maxZ ≈ 47.69`
(chaotic, so envelope-agreeing rather than bit-identical with RK4), and the
Robertson stiff solve conserving mass (Σy = 1.0); increment 4 the simplified
double-pendulum DAE, `constraints maintained through chaos (drift < 1e-6): true`
(~2.8e-8 in practice), and `wrote 1200 frames to double-pendulum.json`.

> **Note on the MTK API.** The increment-3 FFI is validated against
> ModelingToolkit v11 / Symbolics v7 / OrdinaryDiffEq v7. That generation
> renamed several things (`ODESystem` → `System` with explicit unknowns/params,
> `structural_simplify` → `mtkcompile`, a single merged operating-point map for
> `ODEProblem`) and — importantly — `mtkcompile` may reorder the unknowns, so the
> shim reads results back by **symbolic index** (`sol[var]`), never positionally.
> See `julia/ffi-jl/Data_MTKSystem_foreign.jl` for the validated incantations.

## Frontend (`viz/`)

`viz/` is a standalone Hylograph (HATS) Halogen app — its **own** spago workspace
(registry package set `77.5.0`, JS backend), independent of the purejl backend
build and connected only by the JSON the increment-4 run writes. It is a pure
*player*: it loads `double-pendulum.json`, and each ~16ms tick advances a frame
index and re-renders the two rods, three joints, and a fading trail of the second
bob as a declarative SVG tree. The chaotic curve on screen is one the browser
never integrated — Julia's DAE solve did. Build & view:

```bash
cd viz
cp ../julia/double-pendulum.json public/     # the increment-4 output
spago bundle --module DoublePendulum.Main --outfile public/bundle.js
npm run serve                                # http://127.0.0.1:4178
```
