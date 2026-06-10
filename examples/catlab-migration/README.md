# catlab-migration — Tier-3, functorial data migration

The other ACSet superpower beside homomorphism search: **functorial data
migration** — transform structured data *along a schema mapping*, with
categorical guarantees. Here a **Δ (pullback) migration** aggregates a
function-level call graph **up** to a module dependency graph along the `in_mod`
functor: every call `f → g` becomes a module edge `in_mod(f) → in_mod(g)`.

Not a hand-written fold — a migration functor `SchGraph → SchCode` (`V ↦ Module`,
`E ↦ Call`, the graph's `src`/`tgt` ↦ the composite `Call → Func → Module`), and
`migrate(Graph, codegraph, …)` does the rest. The result is a plain Catlab
`Graph` — **exactly the shape Hylograph lays out and renders**. So this both
demonstrates migration *and* produces a Hylograph-shaped artifact:

> describe the fine structure in PureScript → let Catlab derive the coarse view →
> bring it back to draw.

## What it does

A 13-call function graph (8 functions across 4 modules) migrates to **6
inter-module dependencies + 2 intra-module self-loops**, with coupling weights
from the multiplicity:

```
Auth → Db ×2 · Auth → Util ×2 · Db → Util ×1 · Api → Auth ×2 · Api → Db ×3 · Api → Util ×1
intra: Auth ⟲1 · Db ⟲1
```

PureScript aggregates the migrated multigraph (Catlab returns one module edge per
call) into the weighted dependency graph.

## Build & run

Own (Catlab-only) `julia-env`.

```bash
cd examples/catlab-migration
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'   # one-time
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl                   # writes migration.js
```

## View

No server — `window.MIGRATION` `<script>` global:

```bash
cp migration.js migration-viz/      # the run's output
open migration-viz/index.html       # call graph above, derived module graph below
```

## The Catlab ACSet trio

With `catlab-patterns` (homomorphism search on plain graphs), `catlab-schema`
(typed multi-sort schemas), and this (functorial migration), the example set
covers the core ACSet operations — pattern matching and data migration over typed
schemas. Together they are the categorical-data toolkit a **Minard** could lean on:
express the code structure as a schema, query it for architectural motifs, and
migrate between views (function ↔ module ↔ package) — all functorially, with the
results flowing back to Hylograph to render.
