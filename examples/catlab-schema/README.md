# catlab-schema — Tier-3, typed ACSet schemas

Where `catlab-patterns` searches a plain `Graph`, this example uses a **typed
multi-sort schema** — the real ACSet payoff. The schema has two object sorts and
typed morphisms:

```
schema:  Func —in_mod→ Module     Call —src,tgt→ Func
```

A `CodeGraph` instance is a typed code graph (modules, functions typed into
modules by `in_mod`, calls between functions). A **motif** is a small instance of
the *same schema*, and its type structure **encodes the architectural rule**:

- **Cross-module call** — a motif with two *distinct* pattern-modules (`f@A → g@B`)
  matches only calls that cross a module boundary. Found: 6.
- **Shared dependency** — `f@A, g@B → h@C` (two modules calling a third's
  function). Found: 2 — `{login@Auth, route@Api} → query@Db` and
  `{login@Auth, query@Db} → log@Util`.

Catlab's `homomorphisms(motif, graph; monic=true)` finds every occurrence,
respecting the typing. The machinery a **Minard** could use to *express* and
*check* architectural rules (coupling, shared dependencies, layering) rather than
hand-coding each analysis.

## Relation to Hylograph's graphs (a thread to pull)

This is the seam Andrew flagged — how Julia/Catlab graph structures relate to the
PureScript/Hylograph ones. They are complementary, not redundant:

| | Hylograph (PureScript) | Catlab (Julia) |
|---|---|---|
| representation | `purescript-hylograph-graph` — a graph for viz | **ACSet** — a *typed schema* (any C-set; graphs are one schema) |
| strength | **layout** (`-layout`), **force simulation** (`-simulation`, incl. WASM), **rendering** (HATS / `-selection`) | **categorical operations**: homomorphism search (pattern matching), (co)limits, **functorial data migration** |
| query | bespoke traversals per analysis | one generic primitive: `homomorphisms` over any schema |

The natural interop, made concrete by the Jurist seam: **describe a graph in
PureScript** (Hylograph's representation), **ship it to Catlab** for the
categorical work it's strong at — pattern matching, schema migration, colimits —
and **bring the result back to Hylograph** to lay out and render. A Minard could
keep the code graph in Hylograph for visualization and call out to Catlab for
"does this architectural rule hold / where is it violated."

Two follow-ons:

- **Attributes** — give `Func`/`Module` name/layer attributes (`AttrType`) so
  motifs can constrain on data (e.g. "a call from layer N to layer N+2").
- **Functorial data migration** (Δ/Σ/Π) — aggregate the function-level call graph
  up to a module dependency graph along the `in_mod` functor; the other ACSet
  superpower, and a graph Hylograph would then visualize.

## Build & run

Own (Catlab-only) `julia-env`.

```bash
cd examples/catlab-schema
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'   # one-time
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl                   # writes schema.js
```

## View

No server — `window.SCHEMA` `<script>` global:

```bash
cp schema.js schema-viz/        # the run's output
open schema-viz/index.html      # modules as columns, functions inside, matches in accent
```
