# What the Stability Atlas actually costs, and whether it is right

Measured 2026-08-02, M4 MBP, Julia 1.12.6, `-t auto` (6 threads on all three
services). Scenario is the frontend's own preview spec — a ∈ [0.30, 0.85],
e ∈ [0.0, 0.35], 150 Jupiter periods, μ = 9.54e-4, 120×75 = 9,000 pixels.
Median of three runs. Regenerate with `julia --project=. compare.jl`.

## Headline

| | survival sweep | +FLI |
|---|---:|---:|
| architecture tax `poly/native` | **1.00x** | **1.00x** |
| structural distortion `poly_kernel/native_kernel` | 1.00x | 1.00x |
| protocol share of polyglot wall clock | 0.7 % | 0.2 % |
| `ecosystem_forgone` `poly/OrdinaryDiffEq` | **0.19x** | **0.09x** |
| polyglot vs native grid | identical, 9,000/9,000 bit-for-bit | identical |

```
polyglot   4132 ms  = kernel 4101 + encode 30.7     PureScript protocol on Julia
native     4140 ms  = kernel 4109 + encode  1.1     Julia protocol, same kernel
ecosystem 22045 ms  = kernel 22043 + encode  2.1    OrdinaryDiffEq, Vern9 @1e-8
```

**Read the tax as 1.0x within noise, not as a precise 1.00.** An earlier clean
run of the same three services gave 1.03x and 1.02x; median-of-three on a ~4 s
measurement moves a couple of percent between runs. The defensible claim is
that the polyglot service is *indistinguishable from native Julia here*, and
the encode share (0.2–0.7 % across runs) is why.

Three results, in descending order of how much they change what we thought.

---

## 1. Reaching the Julia ecosystem here would cost 5x and buy nothing

`ecosystem_forgone` is **0.19x** — the hand-rolled fixed-step kernel is *five
times faster* than OrdinaryDiffEq for the same answer, and eleven times faster
on the FLI layer (0.09x).

This inverts the plan's step 2, which proposed replacing the hand-rolled RK4
with `OrdinaryDiffEq.solve` on the grounds that reaching the ecosystem "*is*
the exhibit's stated point". It measurably is not worth doing, and — see §4 —
it was never the exhibit's stated point either.

The ecosystem reference is configured to be fair rather than to lose. Every
choice below was made by measurement, on one survivor pixel at 150 periods:

| | | |
|---|---:|---|
| `Vector` state, in-place RHS | 17.5 ms | the obvious first cut |
| `SVector`, out-of-place RHS | 17.2 ms | idiomatic for a small system — **allocation was not the cost** |
| two `ContinuousCallback`s | 11.8 ms | |
| one `VectorContinuousCallback` | 8.9 ms | **-25 %**, and what the reference uses |
| no events at all | 7.1 ms | so event detection is ~21 % of the remainder |
| Vern7 @1e-6 / Tsit5 @1e-6 | 12.3 / 13.6 ms | Vern9 wins at every tolerance tried |
| **fixed-step RK4, 120/period** | **2.9 ms** | |

Note the shape: at 1e-6 Vern9 takes 4,878 steps to the fixed kernel's 59,629 —
**12x fewer** — and is still 2.4x slower with events switched off entirely.
The cost is not arithmetic, it is per-step machinery: error norms, step-size
control, interpolant setup, callback bookkeeping. For 9,000 short independent
integrations wanting a one-number verdict, a scalar fixed-step loop is simply
the right tool, and a general adaptive solver is paying for services this
problem does not consume.

That generalises past this exhibit: **"call the library" is a rule about
expressiveness, not a rule about performance.** The seam rule earns its keep
by keeping *our algorithm* out of the foreign file; it does not follow that
every numerical kernel should become a library call.

## 2. The PureScript layer costs nothing measurable, and seam granularity is why

**Architecture tax 1.00x. The two grids are bit-for-bit identical across all
9,000 pixels**, which is the control saying the harnesses really are running
the same arithmetic, so whatever difference remains is harness alone — and
there is none to speak of.

The PureScript JSON printer *is* several times slower than JSON3 (1.1 ms vs
8.6–30.7 ms per sweep, depending on the run) — and it does not matter, because
it runs 13 times against 4,000 ms of numerics. Protocol encode is **0.2–0.7 %**
of wall clock.

Set against Grid Explorer's 1.22x on the same instrument, the pattern is not
about the backend at all:

| | crossings | work per crossing | tax |
|---|---:|---:|---:|
| Grid Explorer contingency | 42 | ~18 ms | 1.22x |
| Stability Atlas sweep | 13 | ~310 ms | 1.00x |

**The architecture tax is a function of seam granularity against work per
crossing.** Coarse seam, negligible tax. That is a design lever an author
controls, and it is more predictive than any property of the language pair.

## 3. The atlas is right — and it can say exactly where it is not

The honesty meter proves the browser and Julia agree to the last bit. That is
a claim about *reproducibility*; it says nothing about *accuracy*, because
both ends run the same code. The ecosystem reference is the first thing in
this exhibit capable of disagreeing.

**Survival sweep: 8,670 of 9,000 pixels (96.3 %) agree exactly.** Of the 330
that differ, 293 agree that the orbit was lost and differ only on when. **37
pixels — 0.41 % — flip the survived/lost verdict.**

The disagreements are structured, not scattered. They rise monotonically with
eccentricity and avoid the resonances entirely:

```
e in [0.00,0.05)    0.4 %        3:1 (a=0.4807)   0 within +/-0.02
e in [0.10,0.15)    3.2 %        5:2 (a=0.5443)   0
e in [0.25,0.30)    5.8 %        7:3 (a=0.5674)   0
e in [0.30,0.35)    7.4 %        2:1 (a=0.6300)   0
```

**The Kirkwood gaps — the exhibit's headline feature — are reproduced
identically by an independent integrator.** The soft region is the high-e
fringe.

### Which integrator is wrong there? Neither.

The obvious reading is that fixed steps under-resolve eccentric orbits. It is
wrong, and the test that shows it is cheap: refine each integrator and see
whether the verdict settles.

| sample | class flips as fixed step goes 120→960/period | as adaptive tol goes 1e-6→1e-12 | under either |
|---|---:|---:|---:|
| 30 px where they **disagree** | 66.7 % | 70.0 % | **100 %** |
| 30 px where they **agree** (control) | 0 % | 0 % | **0 %** |

Every sampled disagreement is a pixel whose verdict is unstable under
refinement of *at least one* integrator — usually both, non-monotonically
(one pixel went 1.0 → 0.2788 → 1.0 → 1.0 as the step was halved twice). Every
sampled agreement is rock-solid under an 8x step refinement and six orders of
tolerance.

So the disagreement is not error in either integrator. Those pixels sit where
"did this orbit survive 150 periods?" is **discontinuous in the initial
conditions** — the defining behaviour of the chaotic zone the atlas exists to
display. Any discretisation returns *an* answer there; none returns *the*
answer.

**This is not a bug to fix. It is the phenomenon, and the exhibit currently
paints those 330 pixels with exactly the same confidence as the other 8,670.**
That is the real honesty gap in this exhibit — presentational, not numerical —
and switching to OrdinaryDiffEq would not have closed it. It would have cost
5x and changed *which* pixels were indeterminate, not how many.

## 4. What the exhibit actually claims

Worth stating, since the plan's step 2 was written against a claim the exhibit
does not make. The deployed card says:

> Stability Atlas · one wire contract — browser and compute service share
> *one* codec definition … Schema drift is a compile error.

and the design doc's first criterion is "only-in-Julia — a sweep is 10⁴–10⁵
independent ODE integrations, multithreaded native code". Neither is about
reaching Julia's scientific ecosystem. Both are delivered.

The hand-rolled RK4 is load-bearing for a *different* claim: `Atlas.Dynamics`
is the denotation, the Julia kernel mirrors it operation for operation, the
boot self-test confirms it to 0.0 deviation, and the browser re-runs the same
PureScript for the on-screen honesty meter. `asteroidPeriod` spells a^1.5 as
`a * sqrt a` because `sqrt` is correctly rounded everywhere and `pow` is not.
"Call `OrdinaryDiffEq.solve`" and "the browser reproduces the kernel bit for
bit" cannot both be true.

### The check that would have caught the original audit finding

The audit flagged the Atlas for hand-rolled numerics. No timing ratio would
have found that, and structural distortion is blind to it by construction: it
compares the same library call on both sides, and there is no library call.

The check is one line of configuration. **Does the seam import anything?**

```
$ cat service/julia-env/Project.toml
[deps]
HTTP = "cd3eb016-35fb-5094-929b-558a96fad6f3"
```

One dependency, and it is the socket. That is worth *asking* about — and in
this case the answer turned out to be a good one.

## Reproducing

See `README.md` for ports and start commands. Every table above is
regenerable, which is the point of keeping the scripts:

| script | re-derives |
|---|---|
| `compare.jl` | the headline table |
| `solver_selection.jl` | §1, the ecosystem reference's configuration |
| `diffmap.jl` | §3, the eccentricity and resonance breakdown |
| `converge.jl` | §3, the refinement table |
