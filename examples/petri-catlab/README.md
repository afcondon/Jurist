# petri-catlab — Tier-3, AlgebraicJulia

A typed **Petri net** described once in PureScript, whose dynamics Julia derives
**functorially**. This is the Tier-3 keystone of ADR-0007's doctrine: the
*semantics is a functor*, not a hand-written translation.

`Data.Petri` is pure structure — species, and transitions with input/output
species (multiplicity by repetition) and a mass-action rate. The description
crosses the seam once; **AlgebraicPetri** applies the functor from the category of
Petri nets to vector fields (mass-action kinetics) to produce the ODE system, and
**OrdinaryDiffEq** solves it. PureScript never writes a differential equation.

There is no applied-category-theory stack in the JS/WASM world to hand a
description to — this is squarely Julia-exclusive.

Two models ship (SIR and SEIR); they share the *exact* same machinery, only the
typed description differs. The run writes `petri.js` for `petri-viz/`, a static
page that draws each net, shows the derived mass-action ODEs (KaTeX), and plots
the trajectory.

## Why its own workspace + env

The AlgebraicJulia stack (Catlab + AlgebraicPetri) is large; it lives in this
example's own `julia-env/` so it stays isolated from the `numexpr-edsl` MTK/JuMP
environment. The Petri description doesn't use `NumExpr`, so the example is fully
self-contained.

## Build & run

```bash
cd examples/petri-catlab

# one-time: resolve the AlgebraicJulia environment (heavy — pulls Catlab,
# AlgebraicPetri, OrdinaryDiffEq; ~2 min first precompile)
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'

# build PureScript → CoreFn → Julia (run from here so ffi-jl/ is picked up):
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl   # writes petri.js
```

Expected: `SIR … solved, 3 ODE laws derived functorially`, `SEIR … 4 …`, and
`wrote petri.js`. The derived SIR laws are `dS/dt = −inf·I·S`,
`dI/dt = inf·I·S − rec·I`, `dR/dt = rec·I`.

## View

No server needed — the data is a `window.PETRI` global pulled in by a `<script>`:

```bash
cp petri.js petri-viz/        # the run's output
open petri-viz/index.html     # just double-click it
```

## Next

The deeper categorical payoff: **open** Petri nets glued along shared species via
an undirected wiring diagram (`oapply`), so a model built by composing parts has
dynamics that are the composite of the parts' — functoriality made visible.
