# Beat sheet — “Write each computation where it belongs”

**Video 1 of the Polyglot PureScript series.** Mode B: static pages plus two
title slides. No service, no rig, nothing to host.

---

## The register — read this before the script

The video is **not** a tour of category theory, and it should not try to be.
It is Andrew's argument, with the exhibits as evidence:

> Every runtime has libraries the others don't. I want to write each
> computation where it belongs, and keep one typed layer over the top so the
> whole thing still holds together.

**Two voices, and the switch between them is deliberate.**

*Owned.* The intent, the architecture, the dimensions material, and the limits
— spoken with full authority, first person.

*Attributed.* The category theory and the numerics. **“Claude tells me that…”**
is the right form and should be said plainly, without hedging or apology.

**The attribution is the subject, not a caveat.** The reason it is safe to ship
an implementation you did not write and could not fully audit is the typed
layer: totality, dimensional correctness, a codec that will not compile if the
two ends disagree. Say that out loud — it is the most interesting claim in the
video, and it is the one nobody else is making.

That also fixes the running order. **Open where the authority is real**
(dimensions), earn the right to be believed, and only then present the
exhibits you're vouching for at one remove.

---

## Master state

```bash
cd purescript-backends/purescript-julia
python3 -m http.server 4181 --bind 127.0.0.1
```

| | |
|---|---|
| Slides | `http://127.0.0.1:4181/video/opening.html` |
| Pages | `http://127.0.0.1:4181/examples/<path>/index.html` |
| Driver | `video/scroll-driver.js` — paste, `DEMO.check()`, press `0` |
| **Viewport** | **1512 × 889** — Chrome fullscreen on the MBP. Fixed. |

Every beat target below is computed at **1512 × 889**. Change the window and
they all move; `DEMO.check()` will tell you, but the fix is not to change it.

---

## Two verbs, because half these pages don't scroll

Measured at 1512 × 889:

| page | screens | scroll | verb |
|---|---|---|---|
| dimensions | 2.85 | 1645 px | scroll |
| petri | 2.80 | 1604 px | scroll |
| roots | 2.74 | 1548 px | scroll |
| diff | 2.24 | 1106 px | scroll |
| schema | 1.54 | 482 px | **focus** |
| migration | 1.23 | 204 px | **focus** |
| opt | 1.10 | 86 px | **focus** |
| patterns | 1.00 | **0 px** | **focus** |

Four of these are one-screen posters. Scrolling them produces a jitter or
nothing at all — as scripted originally, migration went *down 16 px, back up
to 0, down to 204*. So the driver has a second verb: `focus:` washes the page
toward blank except the element being discussed, and holds the frame still.
That is the right grammar for a poster: you are **pointing**, not travelling.

---

## Beats

### B0 · Opening slides · ~13 s · SILENT

`video/opening.html` — press `0`. Thesis slide, then the architecture. Hold
the last frame, cut.

> No VO. If the architecture slide needs narrating it is too complicated.

---

### B1 · Dimensions — the part you own · est. 90 s

**SHOT** `examples/dimensioned/dimensions-viz/`
**Longest segment in the video, and the one that earns everything after it.**

```js
const BEATS = [
  { at: 'h1',                  hold: 18000 },
  { at: { sel: '.act', n: 1 }, hold: 24000 },
  { at: { sel: '.act', n: 2 }, hold: 26000 },
  { at: { sel: '.act', n: 4 }, hold: 22000 },
];
```
Verified targets: **16 · 294 · 1036 · 1645**.

> **VO (B1a):** I want to start with something I can vouch for personally,
> because it sets up everything else.
>
> **VO (B1b):** A physical dimension can live in the type. Adding metres to
> seconds isn't a runtime error here — it doesn't compile. And it doesn't
> compile on *any* backend, browser included. So this isn't something
> PureScript lacks and Julia provides; it's the typed layer doing its job
> everywhere at once.
>
> **VO (B1c):** But it only works for what's known at compile time. Read a unit
> from a config file, or build an equation at runtime, and the type can't
> follow it there — a runtime checker becomes the only thing that can catch the
> error. Types check what you *write*. They can't check what you *build*.
>
> **VO (B1d):** And the ladder runs out before the end: exponents here are
> integers, so a dimension involving a square root of time isn't expressible at
> all. I'd rather show you that than pretend the approach is total.

⚠️ Do **not** imply types would have prevented a famous units disaster.
`lbf·s` and `N·s` are both mass·length·time⁻¹ — a `Quantity` sees one type and
the addition type-checks. That is the next video.

---

### B2 · The switch · est. 25 s · over the last frame of B1

No page change. This is where the register changes, and it should be explicit.

> **VO (B2):** Everything after this point I did not write. I specified what I
> wanted and Claude designed and implemented it — so when I tell you what these
> do, I'm telling you what Claude tells me they do. That sounds like a caveat.
> It's actually the point: the reason I'm willing to ship code I couldn't
> audit line by line is the layer I've just shown you. The types are the
> contract.

---

### B3 · Exact derivatives · est. 40 s

**SHOT** `examples/numexpr-edsl/diff-viz/` — scroll.

```js
const BEATS = [
  { at: 'h1',                            hold: 14000 },
  { at: { sel: '.katex-display', n: 2 }, hold: 13000, align: 'center' },
  { at: 1.0,                             hold: 13000, align: 'end' },
];
```

> **VO (B3):** Start with something I can still follow. Each expression is
> described once in PureScript as a typed tree, handed across, and
> differentiated symbolically by Julia — the chain rule, quotients and all,
> derived rather than written, and rendered back as LaTeX. A description goes
> across; a description comes back.

---

### B4 · Provably optimal · est. 40 s · **focus**

**SHOT** `examples/numexpr-edsl/opt-viz/` — one screen, 86 px of scroll.

```js
const BEATS = [
  { at: 'h1', hold: 13000 },
  { hold: 13000, focus: { sel: 'section', n: 1 } },
  { hold: 14000, focus: { sel: 'section', n: 2 } },
];
```

> **VO (B4a):** A knapsack. The greedy heuristic — best value-per-weight first
> — runs in pure PureScript and scores twelve.
>
> **VO (B4b):** Handed to a mixed-integer solver, branch-and-bound returns
> eighteen and closes the gap to zero. Not eighteen-and-probably-the-best:
> eighteen, with a certificate that nothing better exists. That distinction is
> the whole reason to leave the browser.

---

### B5 · Rigorous roots · est. 50 s

**SHOT** `examples/numexpr-edsl/roots-viz/` — scroll.

```js
const BEATS = [
  { at: 'h1',                     hold: 12000 },
  { at: { sel: 'section', n: 2 }, hold: 13000, align: 'center' },
  { at: { sel: 'section', n: 3 }, hold: 14000, align: 'center' },
  { at: 1.0,                      hold: 13000, align: 'end' },
];
```
Verified targets: **16 · 570 · 1052 · 1548**. B3 lands on “proven to have no
real roots”, which is the payoff — don't retime past it.

> **VO (B5a):** Same shape again. Claude tells me this library doesn't find
> roots, it *proves* them: each one bracketed in a guaranteed enclosure and
> certified unique.
>
> **VO (B5b):** One root for the cubic, three for this one, four for the
> quartic. And this one — none. But “none” here isn't “I looked and didn't find
> any”; the search is exhaustive, so it's a proof that there are none. I can't
> get that from a numerical root-finder in a browser.

---

### B6 · Structural patterns · est. 45 s · **focus** — zero scroll

**SHOT** `examples/catlab-patterns/pattern-viz/`

```js
const BEATS = [
  { at: 'h1', hold: 12000 },
  { hold: 11000, focus: { sel: '.item', n: 1 } },
  { hold: 11000, focus: { sel: '.item', n: 2 } },
  { hold: 11000, focus: { sel: '.item', n: 3 } },
];
```

> **VO (B6a):** Eight modules, ten dependencies, three shapes to find in them.
>
> **VO (B6b):** A circular dependency — Parser, AST, Eval. **(B6c)** A mutual
> pair. **(B6d)** A diamond. Claude tells me these are found as graph
> homomorphisms from the pattern into the graph — subgraph matching
> generalised, with the category doing the searching. What I can see is that
> one engine found all three without being told what any of them mean.

✅ The cards say **“1 found”**, which is the occurrence count and is correct.
The “3 homomorphisms” figure (rotations of the same triangle) only appears in
terminal output — **keep a terminal out of frame and the contradiction never
arises.**

---

### B7 · Functorial migration · est. 35 s · **focus**

**SHOT** `examples/catlab-migration/migration-viz/` — 204 px; do not scroll it.

```js
const BEATS = [
  { at: 'h1', hold: 12000 },
  { hold: 12000, focus: { sel: 'svg', n: 1 } },
  { hold: 11000, focus: { sel: 'svg', n: 2 } },
];
```

> **VO (B7):** A call graph — eight functions, four modules, thirteen calls.
> And the module dependency graph, which nobody wrote: thirteen calls collapse
> to six module edges, two of them self-loops. Claude tells me this is a
> migration along a functor rather than a fold someone hand-wrote and hoped was
> right, and that the guarantee is categorical.

---

### B8 · Petri nets → dynamics · est. 55 s · the visual peak

**SHOT** `examples/petri-catlab/petri-viz/` — scroll.

```js
const BEATS = [
  { at: 'h1',                            hold: 15000 },
  { at: { sel: '.katex-display', n: 1 }, hold: 16000, align: 'center' },
  { at: 1.0,                             hold: 14000, align: 'end' },
];
```
⚠️ The original beat sheet had a title beat and an SVG beat **43 px apart** —
29 seconds on one unchanging frame. Merged above; `check()` now warns when two
beats land within a third of a viewport.

> **VO (B8a):** Susceptible, infected, recovered, and two reactions. Described
> once in PureScript — species and reactions, and that's all. There are no
> differential equations in the description.
>
> **VO (B8b):** These come back. Claude tells me they're produced by a functor
> from the category of Petri nets to vector fields — the dynamics *derived*
> from the structure of the net rather than translated by hand. Then a solver
> integrates them and the browser draws a trajectory it never computed.
>
> **VO (B8c):** And that's the case for the whole exercise: there's no stack
> like this to hand a description to in the JavaScript world.

---

### B9 · Close · est. 25 s · over the architecture slide

Cut back to `opening.html` slide 2.

> **VO (B9):** So — each computation where it belongs, with one typed layer
> over the top. That layer is what makes the rest safe to accept: it's why I
> can hand the hard parts to a library I don't maintain, or an implementer I
> can't audit, and still believe the result. Next time: why dimensional types
> would not have saved the Mars Climate Orbiter.

---

## Estimated total

| | |
|---|---|
| Slides | ~13 s |
| B1 + B2 (owned) | ~1 min 55 s |
| B3–B8 (attributed) | ~4 min 25 s |
| B9 close | ~25 s |
| **Total** | **≈ 7 min** |

If it must shrink, cut **B7** — the subtlest point and the least visual.

---

## Appendix — ground truth

Verified 2026-08-03 against the page data files. **Do not improvise these.**

| Beat | Claim | Source |
|---|---|---|
| B4 | greedy **12.0**, optimal **18.0**, gap 0 | `opt.js` |
| B5 | roots **1, 3, 0, 4** — cubic / sin / `1+x²` / quartic | `roots.js` |
| B6 | 8 nodes, 10 edges; **1 occurrence each**, over 3 / 2 / 4 nodes | `patterns.js` |
| B7 | 4 modules, 8 functions, **13 calls → 6 module edges**, 2 self-loops | `migration.js` |
| B1 | `meters 1.0 \|+\| seconds 2.0` → `TypesDoNotUnify`, “Could not match type 0 with type 1” | captured compiler output |

**No performance claim anywhere.** This is a capability argument — these
libraries have no counterpart in JS/WASM. Speed is a different video and the
honest answer there is less flattering.
