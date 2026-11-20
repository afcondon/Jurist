# petri-catlab — Tier-3, AlgebraicJulia

A typed **Petri net** described once in PureScript, whose dynamics Julia derives
**functorially**. This is the Tier-3 keystone of ADR-0007's doctrine: the
*semantics is a functor*, not a hand-written translation.

`Data.Petri` is pure structure — species, and transitions with input/output
species (multiplicity by repetition) and a mass-action rate. The description
crosses the seam once; **AlgebraicPetri** applies the functor from the category of
Petri nets to vector fields (mass-action kinetics) to produce the ODE system, and
**OrdinaryDiffEq** solves it. Nobody writes a differential equation into the
description.

The laws the page typesets are a second reading of the same net, written out by
`Data.Petri.massActionLaws` in plain PureScript (it runs on Node and the BEAM
too). They are not the library's output, so the example checks them against it:
at each of the 201 states the solver returns, `Data.Petri.massActionRates` must
match the vector field AlgebraicPetri derived. The Julia foreign file holds
library calls only. Until November 2026 it also built the law text, by hand, and
the page presented that text as what Julia had derived.

There is no applied-category-theory stack in the JS/WASM world to hand a
description to — this is squarely Julia-exclusive.

Two models ship (SIR and SEIR); they share the *exact* same machinery, only the
typed description differs. The run writes `petri.js` for `petri-viz/`, a static
page that draws each net, shows the mass-action laws (KaTeX), and plots
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

# build PureScript → CoreFn → Julia:
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl   # writes petri.js
```

Expected: the lines in `expected-output.txt`, which `bin/demos.py petri-catlab`
holds a run to. The SIR laws are `dS/dt = −inf·I·S`,
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
