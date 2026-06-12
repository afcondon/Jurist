# The Stability Atlas — a two-zone distributed showcase

*Plan, 2026-06-12. Companion to `petri-composition-showcase.md`; realises the
"typed wire contract" item from the near-term queue
(`julia-hosted-purescript.md`, View 2) with orbital dynamics as the content.
Marginalia: Jurist #219, notes 304/305.*

## The demo

An interactive **asteroid stability atlas** for the Sun–Jupiter system. A
browser frontend shows a heat map over a grid of test-asteroid initial
conditions (semi-major axis × eccentricity); each pixel is the verdict of a
real orbit integration in Julia. The Kirkwood gaps — the 3:1, 5:2, 7:3, 2:1
mean-motion resonances that empty the real asteroid belt — emerge in the map
as the sweep streams in. Click any pixel and *that* orbit plays live as an
orrery, streamed from the same service.

Aesthetic target: 3Blue1Brown explanatory quality, Swiss/light Hylograph
styling.

## Why this demo (the criteria it was chosen against)

1. **Only-in-Julia** — a sweep is 10⁴–10⁵ independent ODE integrations,
   multithreaded native code via the existing fused-RGF path (1.006× of
   hand-written Julia, `bench/overhead.jl`). No browser does this
   interactively.
2. **Directly visualizable** — the atlas *is* the computation; the orrery is
   the per-pixel explanation of it.
3. **Genuinely distributed** — browser (PS→JS) and service (PS→Julia) at
   minimum, with a typed protocol between them.
4. **Two interaction zones** — "experiment ⇒ <15 s, progressively painted"
   (the sweep) and "live stream ≥10 fps" (the trajectory). The demo
   deliberately exercises both.

## The thesis it demonstrates

This is ADR-0007 stretched across a network seam: **the wire contract is one
PureScript module compiled to both ends of the wire.** The same
`Atlas.Protocol` ADT + codec resolves against the JS package set in the
browser and against purejl in the service. Schema drift between client and
server becomes a compile error. No OpenAPI, no JSON-schema generator — the
type *is* the protocol.

Secondary theses, inherited from numexpr-edsl:

- The dynamics are a **description**: the planar circular restricted
  three-body problem (CR3BP, rotating frame) written once as a row-typed
  `SystemSpec` in portable PureScript. `integratePure` remains the
  develop-anywhere oracle; the Julia denotation (fused RGF + native
  integrator) is the production executor the sweep engine drives.
- **Descriptions across, handles back**: the browser sends a `SweepSpec`,
  never a callback. Julia owns the inner loop.

## Architecture

```
examples/stability-atlas/
  core/      atlas-core — backend-agnostic, pure PS, no FFI beyond the six
             transcendentals (same shim trick as numexpr-core).
             Atlas.Dynamics   — CR3BP as SystemSpec (state x,y,vx,vy; param mu);
                                initial-condition construction from (a, e);
                                Jacobi constant (the conserved quantity).
             Atlas.Protocol   — the wire contract:
                                ClientMsg = RequestSweep SweepSpec
                                          | RequestTrajectory TrajSpec
                                          | CancelSweep
                                ServerMsg = SweepRows  { rowStart, rows }
                                          | SweepDone  { elapsedMs, stats }
                                          | TrajFrames { frames }
                                          | TrajDone
                                          | ProtocolError String
             Atlas.Json       — minimal pure-PS JSON ADT + printer + parser
                                (runs identically on every backend; the codec
                                itself is part of the differential story).
  service/   atlas-service (purejl) — depends on core + numexpr core/julia
             modules. ffi-jl/:
             Server_WS_foreign.jl     — HTTP.jl WebSocket listener; one socket,
                                        typed messages both ways.
             Atlas_Sweep_foreign.jl   — threaded sweep kernel: grid of (a,e) →
                                        per-pixel integration with escape /
                                        close-encounter events + chaos
                                        indicator; emits row blocks via
                                        callback-to-PS *per block* (coarse
                                        grain, so not the anti-pattern).
             julia-env/               — numexpr julia-env + HTTP.
  web/       atlas-web — Halogen + Hylograph (HATS/canvas), stock JS backend.
             Atlas pane: canvas heat map, paints SweepRows as they arrive;
             axis labels in AU and resonance markers (3:1, 5:2, 7:3, 2:1).
             Orrery pane: streamed trajectory, rotating/inertial frame toggle,
             trails. Controls: grid resolution, horizon (Jupiter periods),
             μ slider (drag Jupiter's mass — every change is a new experiment).
             Honesty meter (M5): in-browser naive RK4 vs the streamed Julia
             solution on the same pixel; live Jacobi-constant drift plot —
             the only-in-Julia claim *visualized*.
```

One WebSocket, the full protocol typed. The sweep is Zone B but arrives
progressively (row blocks), so perceived latency is first-paint, not
completion. The trajectory is Zone A.

## Physics decisions

- **Model**: planar circular restricted three-body problem, rotating frame,
  nondimensional units (Sun+Jupiter mass = 1, Jupiter orbit radius = 1,
  μ = 9.54·10⁻⁴). Standard, well-conditioned, and the Jacobi constant gives a
  built-in integrator-honesty metric.
- **Per-pixel verdict**: survival time against escape (r > r_esc) and
  Jupiter close-encounter (Hill-sphere entry), plus a **Fast Lyapunov
  Indicator** (FLI) — integrate one tangent vector alongside the state
  (8 ODEs total); FLI maps of exactly this system are the classic
  Froeschlé-style pictures of the resonant web, and FLI converges in
  hundreds of Jupiter periods where raw ejection statistics need 10⁴–10⁵.
  Start with survival-time colouring (simplest), add FLI as the quality
  layer; tune horizon × resolution empirically against the 15 s budget.
- **Integrator**: fixed-step RK4 on the fused RGF path first (matches the
  existing keystone benchmark; cheap event checks per step), with the option
  of escalating to an adaptive/symplectic method via the MTK denotation if
  the gap structure demands it. Budget arithmetic: 320×200 px × ~500 periods
  × ~60 steps/period × 8 ODEs ≈ 10¹⁰ flop-ish — seconds, multithreaded
  (`julia -t auto`; the service launch command must set it).

## Milestones

- **M0 — the seam**: HTTP.jl WebSocket FFI; a PS-on-Julia service that echoes
  typed `Atlas.Protocol` messages round-trip. Proves serve-from-purejl.
- **M1 — the contract**: `core/` workspace; `Atlas.Json` + `Atlas.Protocol`
  with print/parse parity-tested Node-vs-Julia in the differential style.
- **M2 — the engine**: CR3BP `SystemSpec`, sweep kernel (threads, events,
  survival colouring), progressive row blocks; tune to budget. CLI test
  harness before any frontend exists (websocat).
- **M3 — the atlas**: web workspace; canvas heat map with progressive paint,
  resonance markers, controls. First end-to-end demo.
- **M4 — the orrery**: trajectory streaming, click-through from atlas pixel,
  frame toggle, trails.
- **M5 — the polish**: FLI layer, honesty meter, μ-slider-as-experiment,
  Marginalia server registration (SDI-compatible: port from env, literal
  port in startCommand, absolute cd), possible site/ section.

## Status (2026-06-12, end of build session 1)

M0–M4 complete; M5 partial (FLI ✓, registration ✓; honesty meter, μ
slider, site section pending). Measured on the MBP (6 Julia threads):

- Full sweep 240×150 @ 150 periods: **~14 s in Julia**, 13 progressive
  blocks, first block ~1.2 s warm. Preview 120×75: ~3.5 s warm. FLI
  sweeps ≈ 2× (combined preview+full ~24 s wall-clock).
- Kernel-vs-oracle self-test at boot: **sum deviation 0.0** after 5000
  RK4 steps — the mirrored Julia kernel is bit-identical to the pure-PS
  `Atlas.Dynamics` denotation.
- Wire-contract parity: 36 TEST lines **byte-identical** Node vs purejl,
  including number formatting and parse errors.
- Trajectory: 2,703 frames / 30 Jupiter periods, Jacobi drift 5·10⁻⁷
  relative (the honesty-meter baseline).
- Survivor FLI distribution @150 periods: regular continuum 3–5 (p50
  4.4, p90 5.1), chaos capped at 8 → frontend rust ramp starts at 0.66
  normalized.
- SDI: both servers registered (Marginalia #219, ids 128/132), WS
  upgrade proxying verified, lazy spawn ~11 s (warm caches; 60 s SDI
  timeout vs ~35 s worst-case cold boot).

Hard-won implementation notes:

- **Julia closures are types**: any FFI body that takes a PS callback
  must hide it behind a `@nospecialize` function barrier or the whole
  body re-JITs per distinct callback (~4 s for the sweep).
- **Warmups must traverse the real reply path** — kernel AND protocol
  encode; a no-op callback leaves the purejl-compiled JSON printer cold.
- One-time ~3 s first-connection JIT remains (HTTP.jl connection path);
  the real fix is a PackageCompiler.jl sysimage — parked.
- purejl emits one Julia `module` per PS module; FFI shims reach sibling
  shims only via explicit sibling import, so co-locate cooperating
  foreigns in one PS module (hence `Atlas.Kernel`).
- spago incremental output went stale once after module deletes/renames
  (bundle silently shipped the old app); `rm -rf output` before bundling
  when modules have been restructured.

## Open questions / parked

- Pure-PS JSON codec performance on 64k-pixel row blocks in the browser —
  if it bites, keep the *types* shared and swap the browser-side decode to a
  JSON.parse-then-walk FFI without touching the contract. Decide on evidence.
- Binary frames (Float32 array) for sweep rows — only if JSON proves too fat.
- Elliptic (non-circular) Jupiter, inclination, secular resonances — content
  upgrades, not architecture changes.
- Other demos on the same harness (magnetic-pendulum basins, ensemble chaos
  cloud — note 305): the harness is the product; demos become content.
