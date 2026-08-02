# The seam-tax lane

**What does it cost to reach a real foreign library from PureScript, versus
reaching it from a plain program in that language?**

```bash
python3 run_seam.py                 # build both arms, run, compare
python3 run_seam.py --skip-build
python3 run_seam.py --json
```

This is the question the backends exist to answer, and until now nothing
measured it. The differential corpus asks whether *meaning* survives the
translation. The canary asks whether a backend has drifted *against itself*.
Both can pass while the answer here is "no, and therefore don't" — because if
reaching the ecosystem costs more than the ecosystem is worth, there is no
reason to be on that runtime rather than on the JS backend.

## The design

Two arms, one loop, one library.

| | |
|---|---|
| **polyglot** | `src/Seam/*.purs` — PureScript owns the loop and calls `OrdinaryDiffEq.solve` once per orbit, through `ffi-jl/Seam_Kernel_foreign.jl` |
| **native** | `native/seam_native.jl` — the identical loop over the identical 400 orbits through the identical solver, as a plain Julia program |

**PureScript owns the loop deliberately.** Handing the whole grid to the
foreign side would make these numbers beautiful and would measure a different
architecture — the one the seam rule forbids, where our algorithm lives in the
foreign file. `Grid.Contingency` calls pandapower 42 times because the N-1 loop
*is* the analysis; this lane sits at the same boundary.

`src/Seam/` is **byte-identical** to `purescript-python/perf-seam/src/Seam/`,
as the canary's shapes and the differential corpus are. Only `ffi-*/` and the
native arm differ, so a difference in the numbers is a difference in the seam
and not in what was asked of it.

### Two axes, because the tax is not a scalar

Two measurements already in hand said so before this lane existed: the
Stability Atlas crosses 13 times with 9,000 floats and pays 0.2 %; Grid
Explorer crossed 42 times with ~1,000 records and paid 44.7 %, falling to 8.1 %
once the payload was narrowed. Same seam machinery, two orders of magnitude
apart. So the call count is held fixed at 400 and the lane sweeps:

- **work per call** — how long the solver integrates (2 → 150 Jupiter periods,
  a 60× range of work bought per crossing);
- **payload per call** — how much comes back (1 → 1024 samples, i.e. 2 → 2048
  `Number`s).

### Checksums gate, timings report

Every row returns an accumulated `Number` and the runner diffs it across arms
*before* it looks at a single timing. A benchmark that computes a different
answer quickly is the classic way for a perf lane to stay green while what it
measures rots.

The gate has already earned it, twice, both times catching a real bug in the
native arm rather than noise: floating-point addition is not associative, so
neither `sum(xs)` (pairwise) nor accumulating straight into the running total
(right association) reproduces `Ref.modify_ (_ + Array.foldl (+) 0.0 xs)`. A
per-array subtotal from `0.0` then one add is what matches. The tolerance is
**relative** — the work-axis checksums are order 400 and the payload-axis ones
order 1.4e4, so a fixed absolute bound would be a different strictness per row.

## Results — Jurist, 2026-08-02, M4 MBP, Julia 1.12.6

```
  work/call     poly      native    tax    distort   crossing
  us            ms        ms                         us/call
  ---------------------------------------------------------
       172       70.6      67.1    1.03     1.02       5.1
       385      158.8     153.5    1.02     1.01       7.8
      1086      439.1     430.6    1.02     1.01      11.7
      3476     1389.9    1373.7    1.01     1.00      23.7
     10139     4038.5    4017.5    1.01     1.00      39.8
```

**Across a 60× range of work per call the tax stayed within 1.01–1.03×.**
Structural distortion never exceeded 1.02, so the seam is not deforming *how*
the library gets called — the failure mode no in-process profiler can see,
because a deformed computation raises foreign *share* and reads as "clean
architecture, the library dominates".

The payload axis is equally flat: 1.00–1.03× from 2 to 2,048 `Number`s
returned per crossing.

### The lane falsified its own design assumption

It was built expecting `crossing` to be **constant** across the work axis, on
the reasoning that a boundary cannot know how long the callee will run. That is
false. Least squares over the work axis:

```
crossing  ~=  6.6 us  +  0.33 % of the library call's duration
```

The fixed 6.6 µs is the boundary. The proportional term cannot be — and is most
likely collector cost tracking a heap the library itself grew, since the
polyglot arm allocates more per call (curried closures, `Effect` thunks) and
garbage collection scales with the heap rather than with the call.

The practical consequence is that **there is no single microsecond figure to
quote**. Reporting a median crossing, as the first version of the runner did,
hides a term that grows. The tax curve is the result; the fit explains its
shape.

### What it means for a seam you are designing

The fixed term sets a floor on how chatty a seam can afford to be:

| for the fixed cost to be under… | each call must buy at least |
|---|---:|
| 5 % | ~130 µs of library work |
| 1 % | ~660 µs of library work |

Both exhibits sit comfortably past that — pandapower's `runpp` buys ~18 ms per
call, the Atlas's sweep blocks ~310 ms — which is why both measured near 1.0.
A seam crossing per *row* of a dataframe would not.

**Verdict for Jurist: practical.** Reaching Julia's library ecosystem from
PureScript costs 1–3 % at any realistic granularity, and the boundary itself is
under 7 µs.

## Caveats

- One library, one problem shape. `OrdinaryDiffEq.solve` returns a small
  struct; a library whose natural return is a large nested object would exercise
  marshalling harder than the payload axis does here.
- Single-threaded on both arms. The Atlas's real sweep is `-t auto`; nothing
  here says what the seam costs under thread contention.
- `reps = 3`, min-of-reps. Rows in the seconds take a couple of percent of
  run-to-run noise, which is the same order as the tax being measured at the
  high end. Read 1.01× as "indistinguishable", not as a precise figure.
