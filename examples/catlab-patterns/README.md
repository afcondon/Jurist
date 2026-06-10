# catlab-patterns — Tier-3, Catlab homomorphism search

Structural pattern-finding by **graph homomorphism search**. A graph and a
*pattern* are both ACSets; Catlab finds every occurrence of the pattern in the
graph as the set of homomorphisms `pattern → graph` — **subgraph matching
generalized to any schema**, with the category doing the searching.

`Data.Pattern` describes a structure (here a module dependency graph) and motifs
(circular dependency, mutual dependency, diamond). The description crosses the
seam once; Catlab returns the matches. This is the engine a **Minard** could use
to flag architectural motifs / violations in a code graph — the original
Petri-net-in-Minard spark, one rung more general.

There is no generic homomorphism-search / ACSet stack in the JS/WASM world.

## What it finds

A 8-module / 10-dependency graph, three motifs, all by the same `homomorphisms(P,
G; monic=true)` call:

- **Circular dependency** (`a → b → c → a`): `{ Parser, AST, Eval }`
- **Mutual dependency** (`a ⇄ b`): `{ Pretty, Codegen }`
- **Diamond dependency** (`a → (b,c) → d`): `{ Core, Parser, Cli, Utils }`

`monic` = injective, so a match uses distinct nodes (a genuine occurrence). The
rotations/orderings homomorphism search returns are collapsed to one set per
occurrence in PureScript.

## Build & run

Its own (Catlab-only) `julia-env`, isolated from the other examples.

```bash
cd examples/catlab-patterns
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'   # one-time
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl                   # writes patterns.js
```

## View

No server — the data is a `window.PATTERNS` `<script>` global:

```bash
cp patterns.js pattern-viz/      # the run's output
open pattern-viz/index.html      # the graph drawn 3× (one per motif), matches in accent
```

## Next (Catlab thread)

- **Typed schemas** beyond plain graphs (ACSets with several node/edge sorts —
  e.g. Module / Function / Type, imports vs calls) so patterns can be cross-sort
  ("a function calling into a module it doesn't import" = an architectural
  violation).
- **Functorial data migration** (Δ/Σ/Π) — transform a code structure along a
  schema mapping, the other ACSet superpower.
