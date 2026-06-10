# Petri-net composition — a Hylograph showcase (design note)

Status: Planned · Date: 2026-06-10

## Why

The `petri-catlab` example (Tier-3) shows AlgebraicPetri deriving mass-action ODEs
*functorially* from a typed Petri net. The deeper AlgebraicJulia payoff is
**compositionality**: build a model by gluing small **open** nets along shared
species (an undirected wiring diagram + `oapply`), and the composite's dynamics
*is* the composition of the parts. Same Lego bricks, different wiring → different
model.

This connects to the original spark: an idle question about Petri nets as a way to
**formalize and visualize state transitions inside Minard**. Composition is the
piece where category theory earns its keep — and visualizing it well is a
graph-layout + direct-manipulation problem, i.e. exactly what Hylograph/HATS is
for. So this demo graduates from a static page to a proper **Hylograph showcase**.

## Backend recipe — DE-RISKED (works in the temp env, 2026-06-10)

The composition pipeline is validated. Key gotcha and fix:

- **"Feet of cospans are not equal"** when composing `LabelledPetriNet` primitives:
  gluing a foot labelled `:Y` to one labelled `:X` at a shared junction fails on
  label mismatch. **Fix: use *unlabelled* `Open(PetriNet(...))` primitives** — feet
  match structurally, and the UWD's junctions name the species.

```julia
using AlgebraicPetri
using Catlab, Catlab.Programs.RelationalPrograms
import OrdinaryDiffEq as ODE

# Two reusable open primitives (unlabelled; every species is a boundary foot)
transmission = Open(PetriNet(2, ((1, 2) => (2, 2))))   # X,Y → Y,Y
transition   = Open(PetriNet(2, (1 => 2)))             # X → Y

# SIR = transmission(S,I) glued to transition(I,R) along I
sir_uwd = @relation (S, I, R) begin
    transmission(S, I)
    transition(I, R)
end
sir = oapply(sir_uwd, Dict(:transmission => transmission, :transition => transition))
net = apex(sir)                       # ns(net)=3, nt(net)=2
sol = ODE.solve(ODE.ODEProblem(vectorfield(net), [990.0,10.0,0.0], (0.0,200.0), [3e-4,0.1]), ODE.Tsit5())
# peak I = 299.578 — IDENTICAL to the monolithic SIR (functoriality confirmed)

# SEIR — the SAME two primitives, rewired (4 species, 4 transitions)
seir_uwd = @relation (S, E, I, R) begin
    transmission(S, I); transition(S, E); transition(E, I); transition(I, R)
end
```

- Composite species order = UWD junction order; solve positionally (plain
  `Vector` u0/rates, not `LVector`).
- **Describing the UWD from PureScript:** a UWD is junctions (named variables) +
  boxes (each a primitive applied to some junctions). Two FFI options: (a)
  metaprogram the `@relation` `Expr` from the data and `eval` it (the same trick
  the NumExpr/MTK shims use), or (b) build the `RelationDiagram` ACSet
  programmatically (`add_junctions!`/`add_box!`/`set_junction!`). (a) is the
  lighter path.

## Frontend — the showcase (to build)

A HATS/Halogen app (its own workspace, registry `77.5.0`), in the showcase idiom,
not the static-page idiom:

- **Primitive palette** — the open nets (`transmission`, `transition`) drawn as
  small open Petri nets with their boundary feet marked.
- **Wiring-diagram canvas** — the UWD: boxes (primitive instances) wired to
  junctions (shared species). The "recipe." Ideally **direct-manipulation** (drag a
  primitive in, wire a foot to a junction) — the Minard/ShapedSteer ethos.
- **Composite net** — the `oapply` result, auto-laid-out (force/layered), updating
  as the wiring changes.
- **Dynamics** — the trajectory of the composite.
- **The reuse story made tangible:** SIR / SEIR / SEIRD as presets over the *same*
  two primitives — flip the wiring, watch the model (and its dynamics) change.

### Open questions

- **Live recomposition** needs a Julia round-trip (describe UWD → oapply → solve)
  per edit — i.e. a running backend service (HTTPurple, à la Calypso), or
  WASM/precomputed presets. For a first showcase, **precomputed presets** (SIR/
  SEIR/SEIRD, each with net + dynamics baked to JSON) avoid the live backend while
  still telling the "same parts, different wiring" story. Live editing is a v2.
- Graph layout for the composite net (the bipartite place/transition graph) — a
  layout pass (the existing `petri-viz` bipartite two-row is a fallback; a real
  force/layered layout is nicer and is Hylograph's wheelhouse).
- UWD construction from data: confirm the metaprogrammed-`@relation` path inside
  the generated purejl module (qualified macrocall, as in the MTK shim).

## Relation to the wider effort

This is the showcase that most directly dogfoods Hylograph (graph viz + direct
manipulation of typed structure) and points at the Minard state-transition idea.
It is the natural home for "operate directly on the elements of a complex system
and see their inter-relationships" applied to *reaction/transition structure*.
