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
                Atlas.Dynamics   CR3BP; rk4Step; Jacobi constant — THE DENOTATION
                Atlas.Protocol   the wire contract: ClientMsg / ServerMsg + codecs
                Atlas.Json       pure-PS JSON ADT, printer and parser
service/      atlas-service (purejl) — HTTP.jl socket, threaded sweep kernel
web/          atlas-web (stock JS backend) — Halogen + canvas, orrery, honesty meter
parity-jl/    Atlas.Protocol.Tests on Julia    } diffed byte-for-byte
parity-node/  Atlas.Protocol.Tests on Node     } — the differential story
bench-jl/     bench-node/  the same, for Atlas.Bench
native/       two Julia reference implementations, and what they measured
```

`core/` is FFI-free on purpose: that is what makes `parity-node` free, and it
is why the browser can re-run the service's exact physics for the honesty
meter.

## Running

```bash
cd service
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'
ATLAS_PORT=3210 julia --project=julia-env -t auto output-jl/main.jl
```

`-t auto` is not optional — the sweep is threaded. Boot takes ~40 s: the
service cross-checks its kernel against the pure `Atlas.Dynamics` oracle
(expected: sum deviation **0.0** after 5,000 RK4 steps) and then warms the JIT
through the full reply path, kernel *and* protocol encode.

Registered in Bosun as Jurist #219: service on 3210, frontend on 3211.

## Why the integrator is hand-written

`service/ffi-jl/Atlas_Kernel_foreign.jl` spells out RK4 rather than calling a
Julia ODE library, and that is load-bearing rather than lazy. It mirrors
`Atlas.Dynamics.rk4Step` operation for operation — same IEEE doubles, same
association — so that the browser can re-run the streamed orbit in lockstep and
show the disagreement live. Measured: **max |Δ| = 0**, bit-identical, on both a
lost orbit and a 30-period survivor. `asteroidPeriod` spells a^1.5 as
`a * sqrt a` because `sqrt` is correctly rounded on every runtime and `pow` is
about a ulp per libm — and one ulp forks a chaotic trajectory.

"Call `OrdinaryDiffEq.solve`" and "the browser reproduces the kernel bit for
bit" cannot both be true. This exhibit chose the second, and `native/` is where
that choice was priced rather than asserted.

## What it costs, and whether it is right

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
