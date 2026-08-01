# Type nesting: why a 1,000-iteration loop takes 14 seconds on Jurist

**Measured 2026-08-01.** A microbenchmark, a mechanism, a prescription, and the
limits of all three.

## The number

A counted `Effect` loop over a `Ref` — no library, just `Ref.modify_` and
recursion — takes **14 seconds for 1,000 iterations** on Jurist, and does not
finish at 4,000.

```purescript
countTo n = do
  r <- Ref.new 0
  let go i | i >= n    = Ref.read r
           | otherwise = Ref.modify_ (_ + 1) r *> go (i + 1)
  go 0
```

| N | first call |
|---:|---:|
| 100 | 0.70 s |
| 400 | 2.97 s |
| 1,000 | 14.0 s |
| 4,000 | did not complete |

Superlinear, and badly.

## It is not execution

Once warm, the same loop runs at **~2.6 µs/iteration**, linear. The cost is
compilation, and `--trace-compile` says exactly how much:

| N | methods compiled |
|---:|---:|
| 20 | 323 |
| 40 | 343 |
| 80 | 383 |

**Exactly `N + 303`. One new method per loop iteration.**

## The mechanism

Julia specialises a method on the *concrete types* of its arguments, and a
Julia closure is a **parametric struct over its captures**. So a closure that
captures a closure has a type that *contains* that closure's type.

`Effect a` is a zero-argument closure ([ADR-0001](design-decisions/0001-runtime-representation.md)),
and `bind` builds a closure capturing the previous one. A recursive `Effect`
loop therefore builds a value whose **type nests one level per iteration**. The
compile trace shows it directly:

```
bindE##3{…, bindE##3{…, bindE##3{…, bindE##3{…}}}}
```

N iterations produce N distinct types, each larger than the last. Julia
faithfully compiles a specialisation for every one of them — which is why the
cost is worse than linear: the number of compilations grows with N *and* so
does the size of the type each one must process.

Nothing here is a Julia bug. It is Julia doing exactly what it promises, to a
program shaped in a way no Julia programmer would write by hand.

## What does not fix it

**`@nospecialize` on `bindE`.** Saves *one* compilation out of 323. That is
diagnostic rather than disappointing: `@nospecialize` suppresses specialisation
on a **method's arguments**, and the nesting is not there — it is in the
**type of the closure that `bindE` returns**. `typeof(bindE(a)(f))` contains
`typeof(a)` and `typeof(f)` by construction, and no annotation on `bindE`
changes that.

**Two toy reproductions also failed**, and instructively. Writing the same
recursion as a top-level Julia function does *not* reproduce the pathology,
because Julia's inference detects the self-recursive cycle and widens to `Any`
— the good outcome. The generated code escapes that limiter because `go` is a
*local* closure held in a `Core.Box` and reached through non-`const` globals,
so there is no statically visible cycle to limit. Worth knowing: the emission
strategy for `let`/`where`-bound recursive functions is itself part of why this
bites.

## What does fix it

Erase the capture from the type — a **concrete, non-parametric wrapper with an
`Any` field**:

```julia
struct Eff; f::Any; end
(e::Eff)() = e.f()
pureE(a) = Eff(() -> a)
bindE(a) = f -> Eff(() -> _run(f(_run(a))))
```

`Eff` is `Eff` at every depth. The nesting stops.

| N | compilations before | after | first call before | after |
|---:|---:|---:|---:|---:|
| 20 | 323 | 312 | — | — |
| 80 | 383 | 312 | — | — |
| 160 | 463 | **312** | — | — |
| 100 | | | 0.70 s | **0.094 s** |
| 400 | | | 2.97 s | **0.094 s** |
| 1,000 | | | 14.0 s | **0.100 s** |
| 4,000 | | | did not complete | **0.117 s** |

Constant compilations, flat wall time, and the results stay correct.

**And steady state improves too**, which was not expected — boxing adds an
allocation per `Effect`, so the honest prior was that first-call would improve
at some steady-state cost. It does not:

| N | before µs/iter | after µs/iter |
|---:|---:|---:|
| 100 | 2.62 | 2.63 |
| 400 | 3.07 | 2.66 |
| 1,600 | **5.82** | **2.67** |

The baseline degrades with N for the same reason it compiles more: the types
keep growing, so dispatch gets more expensive. Boxing is flat. No trade-off was
found on either axis.

## The part that matters beyond `Effect`

**ADR-0001's tag-tuples have the same pathology.** Julia tuples are parametric:

```
Just 1     ::  Tuple{String, Int64}
Just^5 1   ::  Tuple{String, Tuple{String, Tuple{String, Tuple{String, Tuple{String, Int64}}}}}
```

A 20-deep `Cons` cell has a **453-character type**. A `List` of a thousand
elements has a type roughly proportional to its *length*, and every function
that touches it specialises on that type. A non-parametric struct with an `Any`
field stays one type at any depth.

That is a measured, mechanical argument for the struct-per-constructor revisit
([#43](design-decisions/0001-runtime-representation.md)), and it sharpens the
requirement: the win does not come from *structs*, it comes from being
**non-parametric with `Any` fields**. A struct-per-constructor encoding with
typed fields would nest exactly as badly as the tuples do.

### Now measured, not inferred

The paragraph above was written with the type-level fact established and the
*cost* only inferred from the `Effect` mechanism — listed below as a limit of
the finding. The performance canary (`perf/`, built the same day) measured it
within an hour of first running, which is a better argument for the lane than
anything in its README.

`foldl (+) 0 (List.range 1 n)`, first call, Jurist:

| n | first call | f/s | `fold-array` f/s at the same n |
|---:|---:|---:|---:|
| 10 | 216 ms | 17,625× | 2,874× |
| 25 | 447 ms | 13,001× | 4.0× |
| 50 | 1.43 s | 17,303× | 1.6× |
| 100 | 7.11 s | 29,373× | 1.5× |
| 400 | **235 s** | — | — |
| 1,600 | did not finish in 10 minutes | — | — |

The signature is that **`f/s` never settles**. `fold-array` computes the same
sum over the same numbers and returns the same checksum; by n=100 its first
call is within 1.5× of its steady state, because a `Vector{Int64}` is one
type at every length. The list is recompiling at every size, for good, and
the compiler's work grows with the *data*.

Two qualifications, because the table is dramatic and the honest reading is
narrower:

- **Steady state is not the Julia-specific part.** `fold-list` steady is ~27×
  `fold-array` on Jurist at n=100 — and ~20× on the JS reference. Walking cons
  cells costs more than walking a contiguous array on every runtime; that is
  the data structure. The backend-specific finding is entirely in `f/s`.
- **A 100-element list is not a workload.** That the measurement cannot go
  past it *is* the result.

## Limits of this finding

State them, because the numbers above are seductive:

- **One microbenchmark.** An `Effect` loop over a `Ref`. Not the corpus, not a
  real program, not ADT-heavy code.
- ~~**The tag-tuple claim is measured only as a type-level fact.**~~ Closed
  the same day by the performance canary — see "Now measured, not inferred"
  above. It costs more than the `Effect` case, not less.
- **The boxed prototype is a patch to two shims**, not an implementation. Every
  foreign that returns an `Effect` would have to return an `Eff`, and
  `runEffect`-shaped call sites would need to accept both during migration.
- **Allocation was not profiled.** Steady state improved, but the boxed version
  allocates an `Eff` per `Effect`; whether that matters under memory pressure
  is unmeasured.
- **Nothing was checked on Pythia or Gnomon.** Python and Go do not specialise
  on closure types, so neither should show this — which is worth *confirming*,
  because it would make this the first genuinely runtime-specific performance
  finding in the family and a good argument for per-runtime benchmarks.

## Next

1. Confirm the corpus reproduces it, and that Pythia and Gnomon do not.
2. Prototype `Eff` properly in the runtime and re-run the full differential
   suite — correctness first, then the numbers.
3. ~~Measure the tag-tuple cost directly, with a deep `List` fold.~~ **Done**
   — `perf/`'s `fold-list` shape, table above.
4. Only then decide ADR-0001, with the requirement clear: **non-parametric,
   `Any`-typed fields**.

---

## Addendum: there is a source-level answer, and it is better than the fix

Asked whether the computations we actually care about should be written in `ST`
or similar. Measured rather than reasoned about, and the answer is yes —
emphatically, and for a reason that sharpens the whole diagnosis.

**The pathology is not "Effect is slow". It is specifically *recursion that
builds a chain of binds*.** `Effect` and `ST` both ship foreign primitives that
loop **natively in the host**:

```julia
forE(lo) = hi -> f -> () -> begin
    for i in lo:(hi - 1); f(i)(); end
    nothing
end
```

`f` here is one closure, called N times. Its type never grows, so Julia
compiles it once. The bind chain is what nests; a host loop has no chain.

Same program, four ways, N = 1,000:

| variant | wall time | compilations |
|---|---:|---:|
| naive recursion | **224 s** | 1,428 — grows with N |
| `tailRecM` | 0.253 s | 465 — constant |
| `Effect.forE` | 0.065 s | 426 — constant |
| `ST.for` (in `ST.run`) | **0.064 s** | 445 — constant |

`ST.for` holds flat to **N = 100,000 in 0.188 s** — a hundred times the work
that took 224 seconds, done twelve hundred times faster.

Three things follow.

**`ST` is doubly right for a numeric kernel.** It gets the native loop *and*
real mutation *and* stays pure at the boundary — which is the shape Julia wants
anyway. "Reach for Julia because it is good at this" and "write it in `ST`" turn
out to be the same instruction.

**None of this needs a backend change, and all of it is portable.** `ST.for`,
`forE`, `foreachE` and `tailRecM` are ordinary PureScript, work on every
backend, and are already inside the safe subset.

**It reprioritises the boxed `Eff`.** Still worth doing — it is what stops
*naive* code being catastrophic rather than merely slow — but it is no longer
urgent, and it is not the ceiling: `forE` at 0.065 s beats boxed-`Eff`-with-
naive-recursion at 0.100 s. The runtime change is a safety net; the source-level
choice is the performance story.

The cost is that it moves a burden onto the author, who has to know. That is the
same shape as the portability problem, and it wants the same answer: a knowable
boundary rather than folklore. Whether `plimsoll` (or something beside it)
should flag a recursive `Effect` loop as a *performance* hazard the way it flags
an unportable import is an open and rather appealing question.
