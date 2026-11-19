# Stability Atlas

**One PureScript module is the wire contract, compiled to both ends of the
WebSocket.** A browser (PS→JS) and a compute service (PS→Julia) share
`Atlas.Protocol` — the ADTs *are* the protocol, and a field added without
updating a decoder is a compile error on both ends at once.

The content is an asteroid stability atlas for the Sun–Jupiter system: a heat
map over (semi-major axis × eccentricity), each pixel the verdict of a real
orbit integration in the planar circular restricted three-body problem. The
Kirkwood gaps — the 3:1, 5:2, 7:3 and 2:1 mean-motion resonances that empty the
real asteroid belt — emerge as the sweep streams in. Click a pixel and that
orbit plays as an orrery.

Plan and build history: `purescript-julia/docs/stability-atlas-showcase.md`.

## Layout

```
core/         atlas-core — FFI-free, compiles under every backend
                Atlas.Dynamics   CR3BP; rk4Step; Jacobi constant: what the browser steps with
                Atlas.Survival   the same physics as a description: what the kernel is compiled from
                Atlas.Protocol   the wire contract: ClientMsg / ServerMsg + codecs
                Atlas.Json       pure-PS JSON ADT, printer and parser
service/      atlas-service (purejl) — HTTP.jl socket; the kernel compiled from Atlas.Survival
web/          atlas-web (stock JS backend) — Halogen + canvas, orrery, honesty meter
parity-jl/    Atlas.Protocol.Tests on Julia    } diffed byte-for-byte
parity-node/  Atlas.Protocol.Tests on Node     } — the differential story
bench-jl/     bench-node/  the same, for Atlas.Bench
native/       two Julia reference implementations, and what they measured
```

`core/` has no foreign code of its own (it depends on `numexpr-core`, whose
only foreign imports are six math functions), on purpose: that is what makes `parity-node` free, and it
is why the browser can re-run the service's exact physics for the honesty
meter.

## Running

```bash
cd service
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'
ATLAS_PORT=3210 julia --project=julia-env -t auto output-jl/main.jl
```

`-t auto` is not optional — the sweep is threaded. Boot takes ~40 s: the
service compiles its kernel from `Atlas.Survival`, checks it against the pure
`Atlas.Dynamics` (the states must be equal, not close) and then warms the JIT
through the full reply path, kernel *and* protocol encode.

Registered in Bosun as Jurist #219: service on 3210, frontend on 3211.

## Where the integrator is written

In PureScript, once. `core/src/Atlas/Survival.purs` describes the physics: the
rates of change, the initial conditions, the two events that end an orbit.
`Data.Simulation` (in `../numexpr-edsl/core`) builds a Runge-Kutta step from
that description as a program of numbered instructions, and the service has
Julia compile the program to native code and run the sweep on its threads.
No Julia file holds the method.

It used to. Until November 2026 the service's kernel was 320 lines of Julia
written by hand to mirror `Atlas.Dynamics.rk4Step` operation for operation,
because the browser replays an orbit with `Atlas.Dynamics` and the exhibit
shows the two agreeing to the last bit. The page said the atlas was "computed
by PureScript compiled to Julia" while the numbers came from that file. The
generated kernel keeps the property the hand-written one was there for: it
performs the same IEEE operations in the same order. `service` checks this
every time it starts, and `julia output-jl/main.jl check` prints the fuller
account that `bin/demos.py` holds to `service/expected-output.txt`:

- the survival sweep matches the hand-written kernel, kept as
  `native/kernel_fixed.jl`, on 9,000 of 9,000 pixels of the default sweep;
- every frame of two orbits, one that survives and one that is lost, is
  exactly the state `Atlas.Dynamics` reaches after the same number of steps.

"Call `OrdinaryDiffEq.solve`" and "the browser reproduces the kernel bit for
bit" still cannot both be true, and `native/` is where that choice was priced.

**The chaos-indicator layer is still hand-written.** `withFli` sweeps run
`service/src/Atlas/Kernel.jl`, a Julia kernel that integrates a tangent
vector alongside the orbit and renormalises it every 16 steps. That needs a
conditional, which the expression language does not have yet. It is held to
`native/kernel_fixed.jl` by the same check until it can be replaced.

**The browser still steps with `Atlas.Dynamics`,** a second spelling of the
same physics in PureScript, and not with the interpreter of the description.
The two are held equal by the checks above, not by being one piece of code.

## What it costs, and whether it is right

The figures in this section were measured in October 2026, with the
hand-written kernel. They have not been re-measured since the kernel became
generated. The one figure taken since: the default sweep through the service's
own `runSweep` took 3,655 ms on an M4 Mac Mini with 4 threads, of which 23 ms
was the PureScript callback.

`native/` holds two Julia programs with no PureScript in them, both serving
this same protocol, so the exhibit can be measured instead of described. Full
record in **`native/RESULTS.md`**; regenerate with `native/compare.jl`.

| | |
|---|---:|
| architecture tax (polyglot / native Julia, same kernel) | **1.03x** |
| protocol encode, share of sweep wall clock | 0.2 % |
| polyglot vs native grid | **identical, 9,000/9,000 pixels bit-for-bit** |
| `ecosystem_forgone` (polyglot / OrdinaryDiffEq) | **0.20x** |

Three things worth knowing:

**The PureScript layer costs 3 %.** The purejl JSON printer really is ~4x
slower than JSON3 — and it runs 13 times against 4,000 ms of numerics, so it is
0.2 % of wall clock. Compare Grid Explorer's 1.22x at 42 seam crossings against
~18 ms each. The architecture tax tracks **seam granularity against work per
crossing**, not the language pair.

**Reaching the Julia ecosystem here would cost 5x and buy nothing.** The
OrdinaryDiffEq reference is configured to be fair — `SVector` right-hand side,
one `VectorContinuousCallback`, `Vern9` picked over Vern7 and Tsit5 by
measurement — and is still five times slower for the same answer (ten times on
the FLI layer). At tol 1e-6 it takes *12x fewer steps* and is 2.4x slower with
event detection switched off. For 9,000 short independent integrations wanting
a one-number verdict, a scalar fixed-step loop is the right tool.

**96.3 % of the map is integrator-independent, and the exhibit does not say
so.** Two independent integrators agree exactly on 8,670 of 9,000 pixels;
disagreement is zero within ±0.02 of every named resonance, so the Kirkwood
gaps are reproduced identically. The 330 that differ are not error in either
integrator: 100 % of a sample flips its verdict under refinement of at least
one of them, against 0 % of the pixels where they agree. Those pixels sit where
"survived 150 periods?" is discontinuous in the initial conditions — the
chaotic behaviour the atlas exists to display. The exhibit currently paints
them with the same confidence as everything else.

## Known limitation

The frontend hardcodes `ws://localhost:3210`; deploying behind an edge needs
`wss://<host>/atlas/ws`.
