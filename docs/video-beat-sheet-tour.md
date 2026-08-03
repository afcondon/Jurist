# Beat sheet — “Describe it once” (the Jurist static pages)

**Video 1 of the Polyglot PureScript series.** Mode B: static pages plus two
title slides. No service, no rig, nothing to host.

Draft VO is written to be **paraphrased, not read**. It carries the facts and
the shape; the words should end up being yours. Every number below is
ground-truthed in the appendix — those are the things not to improvise.

---

## Master state

Reproduce the run exactly:

```bash
cd purescript-backends/purescript-julia
python3 -m http.server 4181 --bind 127.0.0.1
```

| | |
|---|---|
| Slides | `http://127.0.0.1:4181/video/opening.html` |
| Pages | `http://127.0.0.1:4181/examples/<path>/index.html` |
| Viewport | **1600 × 1000**, browser chrome hidden. Fixed, because beat targets are pixel offsets — see B-note below. |
| Driver | `demo-video-scroll-driver.js`, per-page `BEATS[]` given with each beat |

**Fix the viewport before you time anything.** The beat targets are computed
from element positions, so a different window height moves every landing and
can collapse two beats into one shot. `DEMO.check()` reports that; run it on
every page before its take.

---

## The three passes

As before:

1. **Pass 1 — estimate.** These `hold` values are guesses at your pace
   (~150 wpm, unhurried). I drive the browser; you talk over it in your own
   words. Nothing here is precious.
2. **Pass 2 — measure.** You send the VO; I measure each segment and rewrite
   every `hold` from the real durations.
3. **Pass 3 — the take.** You read against the retimed driver. One pass.

The opening slides run **silent** — narration starts on the cut to Petri.

---

## Beats

### B0 · Opening slides · ~13 s · SILENT

**SHOT** `video/opening.html`, full frame.
**ACTION** Press `0`. Two slides: series context, then the architecture.
Hold the final frame, then cut.

> No VO. The architecture slide has to be readable in silence — if it needs
> narrating, it is too complicated and should be simplified instead.

---

### B1 · Petri nets → functorial dynamics · est. 55 s

**SHOT** `examples/petri-catlab/petri-viz/`
**ACTION** Title → the SIR net → the derived ODEs → the trajectory.

```js
const BEATS = [
  { at: 'h1',                  hold: 14000 },
  { at: { sel: 'svg', n: 1 },  hold: 15000, align: 'center' },
  { at: { sel: '.katex-display', n: 1 }, hold: 16000, align: 'center' },
  { at: 1.0,                   hold: 10000, align: 'end' },
];
```

> **VO (B1a):** This is a Petri net — susceptible, infected, recovered, and two
> reactions between them. It's described once, in PureScript. Species and
> reactions, and that's all: there are no differential equations anywhere in
> the description.
>
> **VO (B1b):** Handed across to Julia's AlgebraicPetri, these equations come
> back. I didn't write them and I didn't translate them. They're produced by a
> functor from the category of Petri nets to vector fields — the mass-action
> dynamics is *derived* from the structure of the net.
>
> **VO (B1c):** Then OrdinaryDiffEq integrates them, and the browser draws a
> trajectory it never computed. What I want to point at is the gap: there's no
> applied-category-theory stack in the JavaScript world I could have handed
> that description to.

---

### B2 · Functorial data migration · est. 45 s

**SHOT** `examples/catlab-migration/migration-viz/`
**ACTION** Title → the call graph → the migrated module graph.

```js
const BEATS = [
  { at: 'h1',                 hold: 13000 },
  { at: { sel: 'svg', n: 1 }, hold: 16000, align: 'center' },
  { at: 1.0,                  hold: 16000, align: 'end' },
];
```

> **VO (B2a):** Same move, different structure. Here it's a call graph — eight
> functions across four modules, thirteen calls between them.
>
> **VO (B2b):** And here's the module dependency graph, which I did not write
> either. It's a migration along a functor: every call from `f` to `g` becomes
> an edge between the module `f` is in and the module `g` is in. Thirteen calls
> collapse to six module edges, and two of those are self-loops — a module
> calling itself. The interesting part is that this is a *functor*, with
> categorical guarantees, rather than a fold I wrote and hoped was right.

---

### B3 · Structural patterns by homomorphism search · est. 50 s

**SHOT** `examples/catlab-patterns/pattern-viz/`
**ACTION** Title → the graph → each of the three motifs.

```js
const BEATS = [
  { at: 'h1',                 hold: 12000 },
  { at: { sel: 'svg', n: 1 }, hold: 12000, align: 'center' },
  { at: { sel: 'svg', n: 2 }, hold: 13000, align: 'center' },
  { at: 1.0,                  hold: 13000, align: 'end' },
];
```

> **VO (B3a):** Eight modules, ten dependencies. I want to find three shapes in
> it: a circular dependency, a mutual dependency, and a diamond.
>
> **VO (B3b):** Catlab finds each one as the set of graph homomorphisms from
> the pattern into the graph. That's subgraph matching, generalised — the
> category does the searching, and the same engine handles all three shapes
> without knowing what any of them mean.
>
> **VO (B3c):** One occurrence of each: a three-module cycle, one mutual pair,
> one diamond.

⚠️ **Do not say “one homomorphism.”** The cycle has **three** homomorphisms and
**one** occurrence — the three rotations of the same triangle canonicalise
together. If a terminal is on screen it prints both numbers seconds apart and
they look contradictory. Say **occurrence**, or explain the rotations; don't
say the count is three, and don't say it's a bug. (`src/Main.purs:25`.)

---

### B4 · Architectural motifs over a typed schema · est. 40 s

**SHOT** `examples/catlab-schema/schema-viz/`
**ACTION** Title → the schema → the two motifs.

```js
const BEATS = [
  { at: 'h1',                 hold: 14000 },
  { at: { sel: 'svg', n: 1 }, hold: 13000, align: 'center' },
  { at: 1.0,                  hold: 13000, align: 'end' },
];
```

> **VO (B4a):** One more turn of the same handle, and this is the one I find
> most convincing. The code graph is now a typed schema — modules, functions
> typed *into* modules, calls — as an instance of a Catlab ACSet.
>
> **VO (B4b):** Each motif is a small instance of that same schema. And because
> it's typed, the *type structure encodes the rule*: a pattern with two
> distinct modules can only match genuinely cross-module structure. I'm not
> filtering results after the fact — the constraint is in the shape I'm
> searching with.

---

### B5 · Exact derivatives, typeset · est. 35 s

**SHOT** `examples/numexpr-edsl/diff-viz/`
**ACTION** Title → hold on two or three worked derivatives.

```js
const BEATS = [
  { at: 'h1',                            hold: 13000 },
  { at: { sel: '.katex-display', n: 2 }, hold: 12000, align: 'center' },
  { at: 1.0,                             hold: 11000, align: 'end' },
];
```

> **VO (B5):** Change of subject — same shape. Each expression is described
> once in PureScript as a typed expression tree, handed over, and
> differentiated symbolically by Julia. The chain rule, quotients and all,
> derived rather than written — and rendered back as LaTeX. A description goes
> across; a description comes back.

---

### B6 · Rigorous roots · est. 50 s — **the strongest beat**

**SHOT** `examples/numexpr-edsl/roots-viz/`
**ACTION** Title → the four functions in turn. Slow down here.

```js
const BEATS = [
  { at: 'h1',                 hold: 12000 },
  { at: { sel: 'section', n: 2 }, hold: 13000, align: 'center' },
  { at: { sel: 'section', n: 3 }, hold: 14000, align: 'center' },
  { at: 1.0,                  hold: 13000, align: 'end' },
];
```

> **VO (B6a):** Four functions, described the same way, handed to Julia's
> IntervalRootFinding. This doesn't find roots. It *proves* them.
>
> **VO (B6b):** Each root comes back bracketed in a guaranteed enclosure and
> certified unique. One root for the cubic, three for this one, four for the
> quartic.
>
> **VO (B6c):** And this one has none — but look at what that means here. The
> search is exhaustive, so “none” isn't “I looked and didn't find any.” It's a
> proof that there are none. That is not a thing I can get from a numerical
> root-finder in the browser.

---

### B7 · Provably optimal · est. 40 s

**SHOT** `examples/numexpr-edsl/opt-viz/`
**ACTION** Title → greedy result → solver result.

```js
const BEATS = [
  { at: 'h1',                     hold: 13000 },
  { at: { sel: 'section', n: 2 }, hold: 13000, align: 'center' },
  { at: 1.0,                      hold: 14000, align: 'end' },
];
```

> **VO (B7a):** A 0/1 knapsack. The greedy heuristic — take the best
> value-per-weight item, repeat — is computed in pure PureScript, and it scores
> twelve.
>
> **VO (B7b):** Handed to JuMP and HiGHS, branch-and-bound returns eighteen,
> and closes the gap to zero. Not eighteen-and-probably-optimal: eighteen, with
> a certificate that nothing better exists.

---

### B8 · Dimensions — where this runs out · est. 70 s · **the close**

**SHOT** `examples/dimensioned/dimensions-viz/`
**ACTION** Title → act 1 → act 2 → act 4. Longest holds of the video.

```js
const BEATS = [
  { at: 'h1',                  hold: 16000 },
  { at: { sel: '.act', n: 1 }, hold: 20000 },
  { at: { sel: '.act', n: 2 }, hold: 18000 },
  { at: { sel: '.act', n: 4 }, hold: 16000 },
];
```

> **VO (B8a):** I want to end on the boundary rather than a victory lap,
> because the boundary is the interesting part.
>
> **VO (B8b):** A physical dimension can live in the type. Adding metres to
> seconds isn't a runtime error here — it doesn't compile, and it doesn't
> compile on *any* backend, browser included. So this isn't something
> PureScript lacks.
>
> **VO (B8c):** But the dimension has to be known when you compile. Read a unit
> from a config file, or build an equation at runtime, and the type can't
> follow it there — a runtime checker is the only thing left that can catch
> the error. Types check what you *write*. They can't check what you *build*.
>
> **VO (B8d):** And the ladder runs out before the end. Exponents here are
> integers, so a quantity whose dimension involves a square root of time is
> simply not expressible. That's where I'll pick this up next time.

⚠️ **Claim discipline for B8.** Do **not** say or imply that types would have
prevented any famous units disaster. Dimensional analysis catches none of them:
`lbf·s` and `N·s` are both mass·length·time⁻¹, so a `Quantity` sees one type
and the addition type-checks. That's the *next* video, and mixing it in here
would overclaim in exactly the way this series exists to avoid.

---

## Estimated total

| | |
|---|---|
| Slides | ~13 s |
| B1–B7 | ~5 min 15 s |
| B8 | ~1 min 10 s |
| **Total** | **≈ 6 min 40 s** |

Comfortably a “quick video”. If it needs shortening, B4 is the one to cut — it
is the subtlest point and the least visual.

---

## Appendix — ground truth

Verified 2026-08-03 against the page data files. **These are the numbers not to
improvise.**

| Beat | Claim | Source |
|---|---|---|
| B2 | 4 modules, 8 functions, **13 calls → 6 module edges**, 2 self-loops | `migration.js` |
| B3 | 8 nodes, 10 edges; circular / mutual / diamond = **1 occurrence each**, over 3 / 2 / 4 nodes | `patterns.js` |
| B3 | cycle = **3 homomorphisms, 1 occurrence** (rotations canonicalise) | `src/Main.purs:25` |
| B4 | 4 modules, 8 functions, 10 calls, **2 motifs** | `schema.js` |
| B6 | roots = **1, 3, 0, 4** for cubic / sin / `1+x²` / quartic | `roots.js` |
| B7 | greedy **12.0**, optimal **18.0**, gap 0 | `opt.js` |
| B8 | `meters 1.0 |+| seconds 2.0` → `TypesDoNotUnify`, “Could not match type 0 with type 1” | captured compiler output on the page |

**Unstated on purpose:** no performance claim anywhere. This video is a
*capability* argument — these libraries have no counterpart in the JS/WASM
world. Speed is a different video, and the honest answer there is less
flattering.
