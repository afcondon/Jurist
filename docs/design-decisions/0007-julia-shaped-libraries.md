# 0007. Julia-shaped libraries: descriptions across, handles back

- Status: Accepted (2026-06-09)
- Date: 2026-06-08

## Context

Jurist's motivating force is leveraging Julia's numeric engine — the
specializing JIT, BLAS/LAPACK, DifferentialEquations / DynamicalSystems /
Catlab. The question this record settles in principle (and the design note
[`../julia-shaped-libraries.md`](../julia-shaped-libraries.md) develops in
full) is *how* an FFI-heavy library should be shaped so PureScript gains those
powers without paying the curried-Dict glue cost (~325 ns/call,
[0001](0001-runtime-representation.md)) on every operation, and without making
Julia's specializer interpret foreign closures.

## Decision (Proposed)

Adopt the **"descriptions across, handles back"** doctrine as the shape for all
Julia-leveraging libraries:

1. PureScript builds a typed *description* (a typed handle, or an eDSL term —
   tagless-final / row-typed, the [ADT-precision](0001-runtime-representation.md)
   and HATS sensibility);
2. the seam is crossed **once**, carrying the description;
3. Julia computes/metaprograms it natively (BLAS, `ModelingToolkit`,
   `RuntimeGeneratedFunctions`);
4. results return as **handles** to Julia-owned data, scoped to an ST-style
   region (rank-2 `run`, so they cannot escape);
5. an explicit `freeze` / `sample` materializes data back into PureScript.

**Callbacks across the seam are the anti-pattern** — a PS closure per inner-loop
evaluation is both slow (the glue cost) and opaque to the specializer. Tiers:
**1** typed ST arrays/matrices, **2** the `NumExpr` / `SystemSpec` eDSL onto
Symbolics/MTK, **3** Catlab / AlgebraicJulia.

Status is **Proposed** because only Tier 1 is built; Tier 2+ will promote it.

> **Progress (2026-06-09):** Tier-2 increments 1 & 2 landed —
> `examples/numexpr-edsl`.
> - **Increment 1** (`Data.NumExpr`): a numeric-expression ADT with
>   `Ring`/`Semiring` ergonomics crosses the seam once (folded through
>   handed-in Julia builders, ADR-0002) and Julia metaprograms it into a native
>   function via `eval` of a generated lambda. A pure PS interpreter gives the
>   reference semantics; the Julia-compiled function matches it byte-for-byte.
> - **Increment 2** (`Data.SystemSpec`): a row-typed system of ODEs — state
>   space and params are PureScript rows, RHS accessed by typed field
>   (`s.x`/`p.sigma`; a misspelt field is a compile error). The vector field is
>   compiled to native Julia and integrated by a native RK4 loop; the Lorenz
>   system reproduces the independent `lorenz-leaf` RK4 (maxZ ≈ 47.83). This is
>   the "Native" evidence-category keystone (Marginalia 220).
>
> (The `record`-package shims the row-typed surface needs — Record.Builder,
> Record.Unsafe.Union — are now built-in `purejl` shims as of 2026-06-09.)

> **Progress (2026-06-09): Tier-2 increment 3 — ModelingToolkit denotation.**
> `Data.MTKSystem` denotes the *same* `SystemSpec` into ModelingToolkit instead
> of the hand-written RK4. The seam is unchanged — PureScript hands across the
> ordered variable names and one RHS `JExpr` per equation (the increment-1
> currency); Julia binds them to Symbolics variables, evaluates the Exprs into a
> symbolic `System`, `mtkcompile`s it, derives the **analytic Jacobian**
> (`calculate_jacobian` — derivatives never written in PureScript), and solves
> with SciML's default adaptive polyalgorithm (auto-switching to a stiff method
> via the Jacobian). The MTK-solved Lorenz matches the increment-2 RK4 /
> `lorenz-leaf` envelope (maxZ ≈ 47.69 vs 47.83 — chaotic, so envelope-agreeing
> not bit-identical), and a genuinely **stiff** Robertson system is solved
> cleanly (mass conserved Σy = 1.0) — something the fixed-step RK4 can't do.
> This is the first non-stdlib Julia dependency (a dedicated `julia-env/`,
> ModelingToolkit v11). `MTKField`/`Solution` are opaque handles; the `Solution`
> samples the dense interpolant lazily (`sampleAt`/`finalState`/`maxComponent`)
> — the "handles back" half, indexed **symbolically** so it is robust to
> `mtkcompile` reordering the unknowns. MTK uses RuntimeGeneratedFunctions
> internally, so increment 3 has no `invokelatest` boundary.
>
> With increment 3 landed, the doctrine is demonstrated across all of Tier 1,
> Tier 2's hand-rolled path, and Tier 2's full symbolic-stack denotation.

> **Progress (2026-06-09): RGF cleanup — status now Accepted.** `Data.NumExpr`
> and `Data.SystemSpec` now compile their staged lambdas with
> `RuntimeGeneratedFunctions` (`@RuntimeGeneratedFunction`) instead of
> `Base.eval` + `Base.invokelatest`: the generated functions are native,
> specialize on their argument types, and are callable in the current world age,
> so the per-call `invokelatest` boundary is gone from the hot loops. Results are
> byte-identical (increment-1 staging faithful; increment-2 Lorenz maxZ 47.834).
> The doctrine is now realised end-to-end with no interpreter/world-age glue on
> any tier, so this ADR is **Accepted**.
>
> Future extensions (not blockers): windowed `SolutionHandle` streaming, and
> Tier-3 (Catlab / AlgebraicJulia).

> **Progress (2026-06-09): Tier-2 increment 4 — DAEs + a Hylograph frontend.**
> `Data.DAESystem` extends the row-typed surface from ODEs to
> **differential-algebraic** systems: a third row of *algebraic variables* with
> no time derivative, plus one closing *constraint* per algebraic variable (the
> constraint lambda returns a `Record alg`, so the count is pinned by type). The
> demo is a double pendulum in Cartesian coordinates; MTK denotes it (state and
> algebraic vars are both functions of `t`, params are not), `mtkcompile`s an
> index-1 DAE keeping the tensions as algebraic unknowns, and `Rodas5P` — an
> implicit stiff integrator — holds the rigidity constraints by Newton iteration
> at every step (rod drift ~2.8e-8 through fully chaotic motion; the result
> crosses back to PureScript, which computes the drift). This is squarely in
> Julia-exclusive territory: `scipy.solve_ivp` has no DAE/algebraic-variable
> support, and the WASM backend has neither a symbolic stack nor an implicit
> solver. The validated formulation uses the *acceleration-level* constraint
> (nonsingular, dividing by `Lᵢ² ≠ 0`) rather than full automatic index reduction
> to an ODE, which introduces a coordinate singularity when a rod is vertical.
>
> The trajectory is materialised to JSON (`dumpFramesJSON`, Julia-side) and
> rendered by **`examples/numexpr-edsl/viz`** — a standalone Hylograph (HATS)
> Halogen app, its own spago workspace on registry set `77.5.0`, connected to the
> backend only by that file. It is a pure *player*: per-tick it advances a frame
> index and re-renders the rods, joints, and bob-2 trail as a declarative SVG
> tree. The chaotic curve drawn in the browser is one it could never have
> integrated — the cross-runtime thesis made visible (one typed description; the
> Julia runtime computes; a PureScript/JS runtime draws).

> **Progress (2026-06-09): overhead benchmark — the staged abstraction is free.**
> `examples/numexpr-edsl/bench/overhead.jl` measures the keystone question: does
> describing a computation in PureScript and crossing the seam once cost anything
> in the hot loop versus hand-written Julia? It integrates Lorenz with one RK4
> loop over three RHS variants (min over 80 samples, post-warmup). Result: a
> single **fused** RuntimeGeneratedFunction over the state/param vectors runs at
> **1.006× hand-written Julia** — the abstraction is free, because the seam is
> crossed once at staging and the hot loop is native Julia calling native code.
> The benchmark also exposed that the *naive* staging shape (N per-equation RGFs
> in a `Vector{Any}`, called `f(args...)` with a runtime-length splat) was ~**21×**
> slower — a per-evaluation dynamic dispatch + splat. `compileFieldJ` was changed
> to emit the fused lambda; Lorenz maxZ is unchanged (47.834). This validates the
> doctrine quantitatively: the cost is in callbacks-per-element (the rejected
> anti-pattern), not in a typed description that compiles once. (This isolates
> FFI/staging overhead, not "Julia vs Python" — that cross-runtime comparison,
> native specialised RHS vs a per-step `scipy` Python callback, is separate.)

## Consequences

- Tier 1 is implemented and verified — `examples/st-number-vector`
  (`STNumberVector` over `Vector{Float64}` + BLAS, `STMatrix` over
  `Matrix{Float64}` + LAPACK factorizations). The region discipline and the
  `freeze`-only materialization hold; the FFI obeys [0002](0002-ffi-shim-doctrine.md).
- Units, sizes, and uncertainty all land on the Tier-2 eDSL (same staging:
  structure crosses once, propagation stays Julia-side) rather than on a
  closure-per-element API.
- The same typed API is intended to deploy in-process (this backend) and, over
  the wire, as a remote-handle protocol — region types then expressing
  *placement*, not just lifetime.

## Alternatives considered

- **Thin API wrappers over Julia libraries.** Rejected as the *shape*: they
  push a callback per evaluation through the seam, defeating specialization and
  paying the glue cost in the hot loop — the exact failure this doctrine avoids.
- **A general `mapNum :: (Number -> Number) -> …`.** Rejected for the same
  reason at micro scale; replaced by a vocabulary of fused kernels plus the
  Tier-2 eDSL for the general case.
