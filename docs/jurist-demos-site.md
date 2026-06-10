# jurist-demos — the site (design note)

Status: Built (2026-06-10, same day) · Date: 2026-06-10

> **Addendum 2026-06-10**: rolled out in full. `site/` now holds the landing
> page (`index.html`, thesis + hero receipt + three tier sections), nine
> example pages (`lorenz`, `pendulum`, `differentiation`, `roots`,
> `optimization`, `petri`, `patterns`, `schema`, `migration`), a shared
> `jurist.css` shell, and `site/data/` with committed copies of every
> example's output data (plus `lorenz.js`, dumped by the new
> `node/src/DumpOrbit.purs` so the plotted orbit is honestly computed by
> `integratePure` on Node). The Lorenz receipts (maxZ `47.8339540885982` on
> Node / BEAM / Julia, byte-identical) were re-run and captured fresh at
> build time. All ten pages verified by headless-Chrome screenshot. Still
> pending from §Build order: Specimen-typeset hero inputs, the
> `jurist-demos` split, Cloudflare Pages deploy.

## The idea

One site that gathers every Jurist example and, for each, **counterposes the clean
PureScript eDSL you *write* against the clean graphics/equations Julia *computes*
from it**. Input on one side, output on the other. That side-by-side *is* the
thesis — "a typed description, and the thing only the Julia runtime can make from
it" — made legible at a glance.

The output halves already exist (the per-example `*-viz/` pages). The new,
unifying element is the **input half**: the actual eDSL source, shown beautifully
beside its result, under one shell.

## Information architecture

A landing page (the thesis + the un-dismissable framing) and a gallery grouped by
tier:

- **One description, many runtimes** — Lorenz `SystemSpec` run bit-identically on
  Julia / Node / BEAM (`integratePure`), plus the double-pendulum DAE.
- **The eDSL (Tier-2)** — exact differentiation, rigorous root finding,
  provably-optimal MILP. (Each: a `NumExpr`/typed description in, a typeset/plotted
  result out.)
- **Category theory (Tier-3, AlgebraicJulia)** — Petri → functorial dynamics,
  homomorphism-search motifs, typed ACSet schema, functorial data migration.

## The per-example template

Two panes:

- **left — "The PureScript you write"**: the *actual* eDSL definition (the
  `lorenz = system \s p -> …`, the `sir = { species, transitions }`, the knapsack
  items, the code graph). Typeset cleanly. Kept honest — extracted from the real
  example source, not paraphrased.
- **right — "What Julia computes"**: the existing viz output (KaTeX equations, SVG
  graphs, plots), reusing each example's render script + `window.*` data global.

Plus a one-line "why only Julia" per example.

## Decisions (recommended)

1. **Build: a static site.** HTML/CSS shell + the existing render scripts and
   committed data `.js`. Matches the existing `file://`-openable pages, the Swiss/
   light aesthetic, and deploys to Cloudflare Pages (cf. `cloudflare-sites`). The
   per-example interactivity already lives in the viz scripts; the site is the
   gallery + the input/output framing. (A Halogen/HATS app is possible later, but
   the content-gallery shape wants a static site.)
2. **Input rendering: clean styled code now, Specimen later.** Start with a
   minimal Swiss-styled code block (muted comments, restrained accents) — honest,
   fast, consistent with `[[demo-typography-good-enough]]`. Specimen (the Sigil
   code-typesetter) is the upgrade for hero examples, once the site exists.
3. **Home: a `site/` dir in Jurist now, split to `jurist-demos` later.** Avoids a
   premature repo; trivially extractable.

## Source-of-truth discipline

The left-pane snippets must be the real eDSL source. Two options: copy the exact
lines (simple, but can drift), or extract a marked region from each `Main.purs` at
build time (honest, a tiny build step). Start by copying; add extraction if drift
becomes a risk.

## Build order

1. One prototype example page (input | output) to lock the shell + the
   counterposition aesthetic.
2. The landing page + nav shell.
3. Roll the template across all examples.
4. (Later) Specimen-typeset the hero inputs; split out `jurist-demos`; deploy to
   Cloudflare Pages.
