# Native references for the Stability Atlas

Two Julia programs with no PureScript in them, both serving the atlas's own
WebSocket protocol, so the exhibit can be measured against something instead of
described.

|  | what it is | what it answers |
|---|---|---|
| `atlas_native.jl` | Julia protocol + JSON3, **the same** hand-rolled fixed-step RK4 | what the PureScript layer costs, arithmetic held fixed |
| `atlas_ecosystem.jl` | Julia protocol + JSON3, **OrdinaryDiffEq.jl** with root-found events | what the ecosystem buys — and whether the atlas is *right* |

Both are drop-in: they speak `Atlas.Protocol` on the wire, so the atlas
frontend can be pointed at either port and works unchanged.

## Why two, and why the second one is not a like-for-like benchmark

Grid Explorer's four ratios all compare **the same library call** made two
ways. The Atlas has no library call — `service/julia-env/Project.toml` lists
exactly one dependency, `HTTP` — so structural distortion there would read
~1.0 however far the exhibit sits from the ecosystem it claims to reach.
*Distortion measures how well you call a library, not whether you called one.*

`atlas_native.jl` is the control. `kernel_fixed.jl` is a deliberate verbatim
copy of the numerics in `service/ffi-jl/Atlas_Kernel_foreign.jl`, so
`poly_kernel / native_kernel ≈ 1.0` is what tells you the two harnesses really
are running the same arithmetic and the remaining difference is harness.

`atlas_ecosystem.jl` changes the arithmetic on purpose. It is the first thing
in this exhibit capable of **disagreeing** with it. The honesty meter proves
the browser and Julia agree with each other to the last bit — a claim about
reproducibility that says nothing about accuracy. A second, independent
integrator is what can speak to accuracy.

It is configured to be fair to Julia rather than to flatter the incumbent:
`SVector` out-of-place right-hand side, one `VectorContinuousCallback` rather
than a `CallbackSet` of two, `Vern9` chosen after comparing Vern7 and Tsit5 at
three tolerances each. See `RESULTS.md` for that selection.

## Running

Ports were taken from Bosun's registry (`GET :3022/api/ports`), **not chosen
by eye** — 3211 looked free and is in fact the Jurist atlas frontend, held by
`bosun serve`, which cost a while of chasing a phantom WebSocket handshake
error.

**Do not register 3212/3213 in Bosun.** Registering them was the obvious next
move and it is wrong: the POST reloads `bosun serve`, which then binds
`127.0.0.1:3212`, and a loopback bind beats these services' `*:3212`. Clients
then reach the router instead of the service — silently, since the connection
succeeds. These are measurement harnesses started by hand for the duration of a
run, not fleet services. (Tracked: the registry conflates "reserved" with
"routable".)

| service | port | start |
|---|---|---|
| polyglot | 3210 | `cd ../service && julia --project=julia-env -t auto output-jl/main.jl` |
| native | 3212 | `julia --project=. -t auto atlas_native.jl` |
| ecosystem | 3213 | `julia --project=. -t auto atlas_ecosystem.jl` |

Each takes 30–90 s to boot: all three warm the JIT through the **full reply
path**, kernel and protocol encode, so that neither side is measured cold.

Then, with the service logs in one directory:

```bash
ATLAS_LOGDIR=/path/to/logs julia --project=. compare.jl
ATLAS_LOGDIR=/path/to/logs julia --project=. compare.jl --json
ATLAS_LOGDIR=/path/to/logs julia --project=. compare.jl --full   # adds 240x150
```

Logs must be named `atlas-polyglot.log`, `atlas-native.log`,
`atlas-ecosystem.log`. All three services write a `sweep-perf` line to stderr
per sweep: the wire's `elapsedMs` covers kernel **and** protocol encode
together, and that split cannot be recovered from outside, so each service
reports it.

Services that are not listening are skipped with a note, so `compare.jl` is
still useful with only the polyglot service up.

**Run it alone.** The wall clock comes from this client and the kernel/encode
split comes from the service logs; if anything else is hitting these ports the
two stop describing the same runs. `compare.jl` checks — if kernel + encode
exceeds the service's own elapsed it says so instead of printing a ratio. That
guard exists because it happened: a `converge.jl` run overlapping a
`compare.jl` run reported the polyglot service as **faster** than native
(0.79x), which is contention, not a result.

## Scenario

`compare.jl` uses the frontend's own specs from `web/src/Atlas/App.purs` —
a ∈ [0.30, 0.85], e ∈ [0.0, 0.35], 150 Jupiter periods, μ = 9.54e-4, preview
120×75 and full 240×150 — rather than a benchmark invented for the occasion.
It is the operating point a viewer actually sees.

## Environment

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

`HTTP` is pinned to 1.x to match `service/julia-env`: the transport must not
be a variable in a comparison of what sits above it. (HTTP 2.x is also not
wire-compatible with the 1.x client here — its `WebSockets.listen` answers the
handshake with 200 rather than 101.)
