# Generated Julia is ~70× slower than the same PureScript on Node

**Status:** open, measured 2026-07-30
**Severity:** strategic — it inverts the backend's value proposition
**Measured by:** `examples/stability-atlas/bench-node` and `bench-jl`, which
compile the *same* `Atlas.Bench` from `atlas-core`

## The numbers

Marginal cost of 2,000,000 fixed-step RK4 iterations of the CR3BP, taken as
`work(4M) − work(2M)` so process startup and JIT are cancelled. All three
produce the identical checksum `1.2793079066898199`, so they are doing the
same arithmetic.

| implementation | runtime | marginal 2M steps |
|---|---|---|
| hand-written, type-annotated Julia (`Atlas_Kernel_foreign.jl`) | Julia | **79 ms** |
| PureScript `Atlas.Dynamics` | Node | **~290–480 ms** |
| PureScript `Atlas.Dynamics` via purejl | Julia | **~27,600–28,000 ms** |

So generated Julia is **~70× slower than the same source on Node**, and
**~350× slower than hand-written Julia doing the identical integration**.

Hand-written Julia beats Node by 4–6×, which is the advantage one would expect
and want. The backend currently gives that away and then some.

## Cause

Not tail calls — TCO is applied correctly, and there is no stack growth. The
generated `integrateSteps` is a proper `while` loop:

```julia
integrateSteps = ((mu) -> ((dt) -> ((function (); local go; go = (function ()
  function _tco_loop(n, s); __v_t1__ = n; if __v_t1__ == 0; return (0, s); end;
  if true; return (1, (((sub1)(n))(1), (((rk4Step)(mu))(dt))(s),)); end; ...
  ((n) -> ((s) -> (begin; _tco_r = (1, (n, s,));
    while _tco_r[1] == 1; _tco_r = _tco_loop(_tco_r[2]...); end; ...
```

The problem is **type instability**, and it is systemic rather than local:

- every value flows through curried closures (`(mu) -> ((dt) -> ...)`) whose
  parameters are untyped, so nothing is `::Float64` anywhere;
- each iteration allocates a tag/payload tuple `(1, (n, s,))`;
- the state `s` is a record, reconstructed per step;
- `rk4Step` reaches the loop as a closure value, not a known callee, so the
  call cannot be devirtualised or inlined.

Julia's performance model is *entirely* type specialisation: the JIT compiles a
fresh, unboxed method instance per concrete argument-type signature. Untyped,
closure-passing, allocation-per-iteration code defeats that completely and
falls back to dynamic dispatch with boxed values. V8, by contrast, is built for
exactly this shape — dynamic, closure-heavy, monomorphic-in-practice — and its
inline caches handle it well.

**This is the one target where our current codegen style is worst.** The same
generated shape costs Node little and costs Julia almost everything.

## Why this matters more than a benchmark

The Jurist story is "reach the Julia scientific ecosystem with types". People
reach for Julia because it is *fast*. A backend that makes numeric PureScript
70× slower than Node has inverted its own pitch — and the fact went unmeasured
until an exhibit was asked to justify a claim about runtime advantage.

`stability-atlas` is not affected in production: its sweep runs on the
hand-written kernel, and the purejl path is the *oracle* (correct, portable,
bit-exact, and slow by design). But that means the exhibit's speed comes from
hand-written Julia, and nothing in the repo currently demonstrates that
`purejl` output is fast on Julia — because it is not.

## Where to look

Type stability is the whole game. Roughly in order of expected payoff:

1. **Uncurry known-arity functions.** `(mu) -> ((dt) -> ((s) -> ...))` should be
   `f(mu, dt, s)` when all applications are saturated, which they are here.
   Curried closures are the root of the untypedness.
2. **Avoid per-iteration tuple allocation in the TCO trampoline.** A mutable
   loop over locals, or `@inline`, rather than rebuilding `(tag, payload)`.
3. **Emit concrete types where CoreFn knows them.** `Number` is always
   `Float64`; annotating parameters would let the JIT specialise.
4. Consider `@inline` / `@inbounds` on generated hot paths, and check
   `@code_warntype` on a generated function as a mechanical gate.

## Reproduce

```bash
cd examples/stability-atlas/bench-node && spago build
node -e 'import("./output/Main/index.js").then(m=>m.main())'        # small
node -e 'import("./output/Main/index.js").then(m=>m.main())' large  # large

cd ../bench-jl && spago build
stack exec --stack-yaml ../../../stack.yaml purejl -- output output-jl
julia output-jl/main.jl          # small
julia output-jl/main.jl large    # large
```

Take `large − small` on each runtime. The checksum must match across both, and
across `Atlas_Kernel_foreign.jl`'s `_rk4_step`, or the comparison is not
measuring the same work.

## Suggested gate

The corpus proves *correctness* across backends and says nothing about cost.
A backend whose selling point is performance should have a performance lane:
one fixed numeric benchmark, run on the generated output, with a recorded
ratio against Node. It would have caught this on day one.
