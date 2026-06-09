# bench — does starting on the PureScript side cost anything? (ADR-0007)

The keystone performance question for the "descriptions across, handles back"
doctrine: a computation is *described* in typed PureScript and crosses the FFI
seam once, then runs on Julia. Does that staging cost anything in the hot loop
versus a 100%-Julia program?

`overhead.jl` answers it for the increment-2 path (a Lorenz vector field compiled
to a native RHS, integrated by a native RK4). It runs one identical RK4 loop over
three RHS variants and reports the minimum over 80 samples after JIT warmup (no
`BenchmarkTools` dependency — runs against the committed `julia-env`):

| variant | what it is | result |
|---------|-----------|--------|
| **(b) hand-written** | the idiomatic Julia RHS a human writes inline | baseline (~103 ns/step) |
| **(c) staged-fused** | a single fused RGF over the state/param vectors — **what the FFI emits today** | **1.006× hand-written** |
| (a) staged-naive | N per-equation RGFs in a `Vector{Any}`, called `f(args...)` with a splat — the shape before we fused | 21.6× hand-written |

```
$ julia --project=julia-env bench/overhead.jl
(b) hand-written          515.67 µs/solve      103.1 ns/step
(c) staged-fused          518.83 µs/solve      103.8 ns/step
(a) staged-naive        11161.42 µs/solve     2232.3 ns/step
staged-fused / hand    : 1.006×   (the SHIPPING path — ≈1.0 ⟹ the abstraction is free)
staged-naive / hand    : 21.645×  (the per-eq Vector-splat shape we fused away)
one-time staging cost  : 0.056 ms
```

## What it shows

- **The staged abstraction is free.** A typed PureScript description compiles to
  code that runs at hand-written-Julia speed (within ~1%). Starting the data on
  the PureScript side of the FFI is *not* a performance penalty — because the
  seam is crossed once, at staging, not per-evaluation. The hot loop is native
  Julia calling a native RuntimeGeneratedFunction; the FFI is nowhere near it.
- **The benchmark earned its keep** by exposing that the *naive* staging shape (N
  per-equation RGFs in a `Vector{Any}`, splatted) is ~21× slower — a dynamic
  dispatch + runtime-length splat on every RHS evaluation. `compileFieldJ` now
  emits a single fused RGF instead, closing the gap to ~1.0×.

## What it is NOT

This isolates *FFI/staging overhead*, not "Julia vs Python". It does not claim
Julia beats NumPy on BLAS-bound dense linear algebra (everyone calls the same
BLAS). The Julia win against `scipy.solve_ivp` is a different axis — the native,
specialised RHS in the solver loop vs a per-step Python callback — and would be a
separate cross-runtime benchmark for the comparison site.
