# numexpr-edsl — the Tier-2 eDSL (ADR-0007)

A typed PureScript eDSL that crosses the PureScript→Julia seam **once** as a
*description* and is denoted into Julia's numeric stack — the answer to the
`mapNum` callback anti-pattern (a PureScript closure per inner-loop evaluation
is slow and opaque to Julia's specializer). Three increments, each building on
the last:

1. **`Data.NumExpr`** — a numeric-expression precision ADT with `Ring`/`Semiring`
   ergonomics (`num 10.0 * (var "y" - var "x") + sinE (var "z")`). It crosses the
   seam once (folded through handed-in Julia builders — the shim never
   destructures a PureScript ADT, per ADR-0002) and Julia metaprograms it into a
   native function via `eval`. A pure PureScript interpreter gives the reference
   semantics; the Julia-compiled function matches it **byte-for-byte**.

2. **`Data.SystemSpec`** — a **row-typed** system of ODEs: state space and
   parameters are PureScript rows, so the RHS is written with typed field access
   (`s.x`, `p.sigma`; a misspelt `s.q` is a compile error). The vector field is
   compiled to native Julia and integrated by a hand-written **RK4** loop; the
   Lorenz system reproduces the independent `examples/lorenz-leaf` (maxZ ≈ 47.83).

3. **`Data.MTKSystem`** — the *same* `SystemSpec`, denoted into
   **ModelingToolkit** instead of a hand-rolled integrator. The equations become
   a symbolic `System`; `mtkcompile` simplifies it; MTK derives the **analytic
   Jacobian** (derivatives never written in PureScript); and SciML's default
   adaptive solver — a polyalgorithm that auto-switches to a stiff method when it
   detects stiffness — integrates it using that Jacobian. Demonstrates two things
   the fixed-step RK4 can't: the derived Jacobian, and a genuinely **stiff**
   system (Robertson) solved cleanly.

The seam is identical across all three (ADR-0007, "descriptions across, handles
back"): PureScript hands over a typed description; Julia owns the computation;
results return as handles (`Compiled`, `Field`, `MTKField`/`Solution`) and are
materialised only on demand.

## Build & run

All three increments run under a **dedicated Julia environment** in `julia-env/`
(kept out of your global environment; `Manifest.toml` is gitignored, so resolve
it once). Increments 1 & 2 use the lightweight `RuntimeGeneratedFunctions`
(native, specializing RHS functions with no `invokelatest` boundary); increment
3 adds ModelingToolkit:

```bash
# one-time: resolve the MTK environment (heavy — pulls ~220 packages)
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'

# build the PureScript, emit CoreFn, generate Julia (run from this directory so
# the project-specific shims in ffi-jl/ are picked up):
spago build
stack exec purejl -- output output-jl     # or: purejl output output-jl

# run with the MTK environment active so `using ModelingToolkit` resolves:
julia --project=julia-env output-jl/main.jl
```

Expected: increment 1 `staging faithful: true`; increment 2 Lorenz `maxZ
47.834`; increment 3 the printed simplified equations + analytic Jacobians, the
MTK-solved Lorenz `maxZ ≈ 47.69` (chaotic, so envelope-agreeing rather than
bit-identical with RK4), and the Robertson stiff solve conserving mass (Σy = 1.0).

> **Note on the MTK API.** The increment-3 FFI is validated against
> ModelingToolkit v11 / Symbolics v7 / OrdinaryDiffEq v7. That generation
> renamed several things (`ODESystem` → `System` with explicit unknowns/params,
> `structural_simplify` → `mtkcompile`, a single merged operating-point map for
> `ODEProblem`) and — importantly — `mtkcompile` may reorder the unknowns, so the
> shim reads results back by **symbolic index** (`sol[var]`), never positionally.
> See `ffi-jl/Data_MTKSystem_foreign.jl` for the validated incantations.
