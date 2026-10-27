# The performance canary

The differential suite answers *does this mean the same thing on both
runtimes?* This lane answers the other half: *and does it still cost what it
cost yesterday?*

```bash
cd perf
python3 run_perf.py                    # build, run, check
python3 run_perf.py --skip-build --echo # re-run, streaming
python3 run_perf.py --update-baseline   # re-record THIS machine's baseline (say why)
```

## What it is for

Until now nothing in this repo would have noticed a code-generator change
that made a common shape ten times slower. The type-nesting finding of
2026-08-01 — a 1,000-iteration `Effect` loop taking 14 seconds — was found by
accident, while writing a test for something else. That is not a process.

The question the lane asks is **"has this backend drifted against itself?"**
Cross-runtime numbers fall out of the table and are printed, but they are not
the claim and should not become the framing. The shapes are chosen to be
*attributable*, not to be representative of real programs, so "Julia is
faster than JavaScript at X" is not a conclusion this lane supports.

## Two axes

The shapes cover both halves of what "performance of PureScript on this
runtime" means:

- **common computational patterns** — counted loops four ways, folds over a
  list and over an array, `map`, string building, record update
- **cost of the FFI seam** — `ffi-call` is `loop-fore` with the increment
  moved to the far side of the boundary, so their difference is the per-call
  crossing cost; `ffi-array` crosses once with n elements, so it measures
  marshalling instead

## Three design decisions worth knowing

**Timing lives in PureScript** (`Bench.Main`), not in the runner. Every
backend therefore executes byte-identical measurement code. A per-backend
harness written in the host language is the obvious alternative and it is
worse: it drifts, and the drift is invisible because it presents as a
performance difference.

**First call and steady state are reported separately.** Conflating them is
what made Jurist's first performance number uninterpretable — "170 ms per
iteration" was 99% compilation. Sizes for a shape run in ascending order
within one process and the first call at each size is timed on its own. That
first call is not a warm-up artefact to be discarded; on Julia a size that
demands types no smaller size demanded compiles again, so *first-call cost
growing with n* is the type-nesting signal itself.

**The baseline stores ratios, not milliseconds.** An absolute baseline is
worthless the moment it leaves the machine that recorded it. Each shape is
normalised, within its own backend and its own run, against `loop-fore` at
n=10000:

| column | meaning |
|---|---|
| `rel` | steady(shape) / steady(calibration) — cost relative to a plain host loop on the same runtime |
| `f/s` | first / steady — how much of the first call is compilation |

Machine speed cancels *within a machine*; it does not make the baseline
portable, and the next section but one says why the baselines are now per
machine. `f/s` is the
type-nesting signal in one number: ~1 on a runtime that does not compile per
call site, and large — and *staying* large as n grows — exactly where
specialisation is happening.

## Checksums gate; timings report

Every shape returns an `Int` checksum, and the runner diffs checksums across
backends **before it looks at a single timing**. A benchmark that computes
the wrong answer quickly is the classic way for a performance suite to stay
green while the thing it measures rots.

## Drift gates too, but only on rows that can carry a gate

Timing drift is a failure as well (`--gate-drift`, on in `bin/conformance.sh`).
It was not, when the lane was first built, and what changed is worth stating
precisely, because it is not what it looks like.

**The tolerance did not change.** It is still 2×. What changed is the
population it applies to, and the size of the thing everything is divided by.

The original calibration was `loop-fore` at n=1000, which at five reps is six
thousand iterations — not enough work for a tiering JIT to finish tiering.
The JS reference measured that shape at 114, 135, 167, 188 and 196 µs on the
same idle machine on the same day. Every `rel` in the table is divided by that
number, so the lane's noise floor was being set by its own denominator. The
tell was visible in the baseline and went unread: `loop-fore@10000` recorded
`rel` 10.4 on Jurist — linear in n, as a host loop should be — but 6.3 on JS,
not because the JS loop is sublinear but because its denominator was slow.
At n=10000 the calibration reads 1020/1027/1023 µs across runs.

That fixed the denominator but not the tail. Six back-to-back runs of all
three backends (2026-08-01, idle M4 MBP) put the worst run-to-run spread at:

| population | rows | median | 90th | worst |
|---|---|---|---|---|
| every measured row | 258 | 1.13× | 1.35× | **5.74×** |
| largest n of each shape | 78 | 1.10× | 1.26× | 1.69× |
| steady ≥ 50 µs | 123 | 1.10× | 1.27× | 5.74× |
| **both — the gated population** | 56 | 1.10× | 1.21× | **1.69×** |

A 2× gate over the first row would have fired on noise nearly every run. Over
the last it has 1.18× of headroom over the worst thing noise managed in six
tries. So the runner marks a row **gated** when it is both:

1. **the largest n of that shape** — the smaller sizes exist to show the
   *curve*, superlinearity and `f/s` growth, which is a diagnostic and not a
   threshold; and
2. **above `GATE_MIN_STEADY_US`** (50 µs) — below that, scheduler noise and
   timer resolution dominate. `ffi-array@1600` on the JS reference is ~20 µs
   and swings 1.5× between runs while doing identical work.

Ungated rows are still measured, still printed, and still reported as drift —
they just carry `(report only)` and cannot fail a build. Nothing is hidden.

The gate flag is decided when the baseline is **recorded**, and travels in it.
Recomputing it per run would make a shape near the 50 µs line gate on one run
and not the next. It is therefore a property of the recording machine: on a
slower box this excludes rows that would have been measurable there, which
costs a little coverage and never invents an alarm.

Two consequences worth knowing:

- `fold-array` is never gated on any backend, by design. It is `fold-list`'s
  control rather than a subject, and array traversal is gated through
  `map-array` instead.
- `ffi-array` and `string-join` run to n=12800 for no reason other than this.
  At 1600 both sat under the floor on every backend, so neither was gated
  anywhere — and `ffi-array` is one of the two shapes that measure the FFI
  axis this corpus was built around. **A shape that cannot fail the gate is
  not protected by it.**

Tighten toward the 90th percentile once a few weeks of CI runs say what the
tail really looks like; six samples underestimate it.

A shape that does not complete is recorded as **DNF** rather than crashing
the lane — see below for why that is a normal outcome here.

## A speed index, and one baseline per machine (2026-10-27)

Two holes in the gate above, found in the October review (REVIEW-2026-10, X3
c and e):

**A uniform change was invisible.** Every `rel` is divided by the same run's
`loop-fore`, which this backend compiles too. A code-generator change that
moves every shape by the same factor moves the denominator by it as well,
and cancels. In Pythia, a change that made every closure-heavy shape about
20 % faster passed the gate without a line of output. So each backend now
also gets a **speed index**: the geometric mean, over its gated shapes, of
steady(backend) / steady(js) for the same shape in the same run. JS is
compiled by `purs`, which nothing in this repo touches, so the index moves by
exactly the size of a uniform change. The index is gated at
`INDEX_TOLERANCE` = 1.10 either way, and both directions fire: a speedup the
gate cannot place is still a change that should re-record the baseline on
purpose.

**The baseline was not portable.** The ratios were described as machine
independent, and they are not: the first run on GitHub's x86 runners put
gated JS rows at 2.17x and 0.38x of the M4 baseline with nothing changed,
because V8 and Julia do not speed up together across CPUs. Baselines now live
in `baselines/<host>-<cpu>.json`, one per machine, written by
`--update-baseline` for the machine it runs on. On a machine with none, which
is every CI runner since a runner's host name is new each run, the drift gate
prints **NOT RUN** and, on Actions, raises a warning annotation. Checksums
gate everywhere. The old `baseline.json` was recorded on the MBP and is gone;
the MBP gets its gate back by recording its own file.

**Rounds and medians.** Every backend runs `--repeat` times (default 3),
interleaved by round (js, jl, backend-jl, js, …), so a change in machine
load lands on numerator and denominator alike, and each shape takes the median
of its rounds. The report prints the per-round indices; if their spread is
wider than the tolerance the verdict is marked **NOISY**, since that run
cannot vouch for it either way. Three rounds cost about 70 s here, with the
build, so Jurist keeps the default.

**The optimizer lane is in the canary.** `backend-jl` runs the same corpus
(emitted per `Bench.Main` exactly as `backend-jl/run_conformance.sh` does,
with the oracle lane's runtime and shims), has its own checksums cross-checked
and its own index. It owns its own code generator, so it needs its own
guard. When `../purescript-backend-optimizer` is not checked out, the canary
says the lane was NOT RUN rather than leaving it out of the table.

### The noise behind 1.10 (Mac Mini M4, loaded, 2026-10-27)

Nine back-to-back runs of unchanged code at `--repeat 3`:

| run | jl index | backend-jl index |
|---|---|---|
| 0 (with build) | 8.123 | 1.429 |
| 1 | 8.026 | 1.443 |
| 2 | 8.014 | 1.439 |
| 3 | 8.031 | 1.433 |
| 4 | 8.020 | 1.447 |
| 5 | 8.138 | 1.445 |
| 6 | 8.152 | 1.423 |
| 7 | 7.986 | 1.468 |
| 8 | 8.072 | 1.448 |
| **max/min** | **1.021x** | **1.032x** |

The baseline (`baselines/andrews-mac-mini-apple-m4.json`) was recorded
straight after, at jl 8.010 and backend-jl 1.443.

### Replay: Jurist#3 (PSData/PSEff) through the new gate

The open PR that erases value depth from types, merged locally onto this
branch and run three times with `--gate-drift`. The gate fails all three runs:

| run | jl index | backend-jl index | per-shape |
|---|---|---|---|
| 1 | 0.933x (NOISY: rounds 1.107x apart) | 0.830x MOVED | fold-list@100 0.32x (jl), 0.29x (backend-jl) |
| 2 | 0.894x MOVED | 0.850x MOVED | fold-list@100 0.30x, 0.25x |
| 3 | 0.920x ok | 0.826x MOVED | (same) |

Jurist#3 is not a uniform change. On jl, fold-list gets about 3x faster,
loop-naive about 16 % faster and loop-tailrec about 16 % slower. So jl's index
moves by about 8 %, close to the bound, while backend-jl, which shares the
runtime, moves by 17 %. The per-shape gate already catches fold-list, the
largest of its effects. What the index adds is the verdict on the whole
backend. If Jurist#3 is taken, it re-records this machine's baseline in the
same PR.

## First calls and start-up, with a tolerance per runtime (2026-10-27)

The speed index is steady state only. Jurist#3 cut the corpus's first calls
on Julia from 7.3 s to 0.55 s, which is the change a Julia user feels most,
and no gated number moved. So each run now records two more numbers per
backend, identically in all three repos (the header of `run_perf.py` has the
reasoning):

- **first-call index**: the sum of first-call times over every shape and
  size, divided by the same sum on JS in the same run;
- **start-up**: ms from spawning the process to its first line of output,
  the median over rounds, against this machine's baseline in ms. It is not a
  ratio to JS, because node's ~60 ms start-up moved 30 % between runs under
  load while Julia's 9.3 s moved under 2 %.

Gnomon's psgo lane now runs a binary built in `build()` rather than `go run`,
so start-up times the program and not Go's compiler.

### Tolerances

| runtime | first-call index | start-up |
|---|---|---|
| Julia | 1.25x | 1.25x |
| Python | 2.0x | not gated |
| Go | 1.5x | not gated |

A number that is not gated is still printed on every run, and the line says
`not gated on <runtime>, recorded only`.

### The noise behind them

Every run of an unchanged tree at `--repeat 3`. The Mac Mini M4 was at load
10–14 throughout (an smbd copy holding about seven cores); there was no
quieter window. BlackStar (Intel i5-6267U, 4 cores, Linux) was idle, each
run starting at a 1-minute load of 0.46–0.49; its runs used julia 1.13.1
against the Mini's 1.12.6.

| lane | first-call index, Mini | spread | idle BlackStar | spread | start-up, Mini | spread | BlackStar |
|---|---|---|---|---|---|---|---|
| jl | 65.1–68.6x js (9 runs) | 1.05 | 56.3–57.7x (4) | 1.03 | 9.25–9.40 s | 1.02 | 21.2 s |
| backend-jl | 29.6–35.1x | 1.19 | 18.9–19.4x | 1.03 | 278–295 ms | 1.06 | 576–593 ms |
| py | 14.6–21.3x (7 runs) | 1.46 | 11.1–11.6x | 1.05 | 27–74 ms | 2.74 | 55–56 ms |
| backend-py | 0.87–1.24x | 1.42 | 0.94–0.98x | 1.05 | 19–38 ms | 2.00 | 30–35 ms |
| go | 3.20–3.49x (7 runs) | 1.09 | 2.57–2.71x | 1.06 | 3–4 ms | — | 2 ms |
| backend-go | 0.76–0.82x | 1.08 | 0.59–0.65x | 1.10 | 3–5 ms | — | 2 ms |

Most of the Mini's spread is load: on the idle machine every first-call
index stays within 1.10x. The tolerances are set for the loaded Mini, the
machine that gates, so on a quiet machine they are looser than they need to
be. Julia's started at the speed index's 1.10 and moved to 1.25 after one
run of an unchanged tree read backend-jl at 0.902x.

Start-up on the Jurist oracle lane is 9.3 s on the Mini: loading and
compiling the emitted program before any PureScript runs. That is
seventeen times its first calls and thirty times backend-jl's start-up.

### Replaying Jurist#3

`main` from before Jurist#3 (b62de96, with this `run_perf.py`) against the
baseline recorded after it, alternating with `main`, `--gate-drift`, at
the first Julia tolerance of 1.10:

| run | jl first-call index | backend-jl first-call index | steady index | exit |
|---|---|---|---|---|
| before #3, 1 | 12.77x MOVED | 15.43x MOVED | ok (0.98x, 1.06x) | 1 |
| before #3, 2 | 12.95x MOVED | 15.72x MOVED | ok (0.97x, 1.06x) | 1 |
| main, 1 | 1.02x ok | 0.90x: MOVED at the first tolerance, 1.10; ok at 1.25 | ok | 1 (at 1.10) |
| main, 2 | 1.03x ok | 1.02x ok | ok | 0 |

The steady index passed the pre-#3 tree both times, and the per-shape drift
on `fold-list` was report-only. Only the first-call index saw the change.

## What the first run found (2026-08-01, M4 MBP)

The lane paid for itself before it had a baseline.

**`fold-list` is the tag-tuple pathology, measured.** On Jurist a `Cons`
cell's type contains its tail's type (ADR-0001), so an n-deep list has an
n-deep type and the compiler does work proportional to the *data*:

| n | first call | f/s |
|---:|---:|---:|
| 10 | 216 ms | 17,625× |
| 25 | 447 ms | 13,001× |
| 50 | 1.43 s | 17,303× |
| 100 | 7.11 s | 29,373× |
| 400 | **235 s** | — |
| 1600 | did not finish in 10 min | — |

The signature is that `f/s` **never settles**. `fold-array` — same numbers,
same sum, same checksum, flat representation — is down to 1.5× by n=100. That
is a measured answer to what was previously only a type-level observation
(a 20-deep `Cons` prints as a 453-character type), and it is step 3 of
task #53 done ahead of schedule.

Two honest qualifications:

- **Steady state is not the Julia-specific part.** `fold-list` steady is ~27×
  `fold-array` on Jurist and ~20× on JS at n=100. Walking cons cells costs
  more than walking a contiguous array everywhere; that is the data structure,
  not the backend. The Julia-specific finding is entirely in `f/s`.
- **These sizes are absurdly small.** A 100-element list is not a workload.
  That the lane cannot go past it *is* the finding.

**Why the schedule is ordered the way it is.** The pathological shapes run
last, so a lane that hits its timeout still delivers most of the table, and
the corpus flushes stdout after every line so that a timeout yields both the
completed measurements and the identity of the shape that hung. Both of those
came directly from the first run, which spent ten minutes producing nothing
because Julia block-buffers a redirected stdout.

## Files

| | |
|---|---|
| `src/Bench/Shapes.purs` | the shapes — **shared corpus**, byte-identical across the three backend repos |
| `src/Bench/Main.purs` | the harness and the schedule — also shared |
| `src/Bench/Clock.purs` | the one foreign: a monotonic clock, a stdout flush, and the two FFI probes |
| `src/Bench/Clock.js`, `ffi-jl/Bench_Clock_foreign.jl` | its implementations |
| `run_perf.py` | build, run, derive ratios and the speed index, compare — **per-backend** |
| `baselines/<machine>.json` | one machine's recorded ratios, speed indices, first-call indices, start-up and checksums |
| `scratch/` | the ad-hoc scripts that produced the original finding, kept because the finding doc cites them |
