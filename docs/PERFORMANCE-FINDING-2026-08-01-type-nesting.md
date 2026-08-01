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

## Limits of this finding

State them, because the numbers above are seductive:

- **One microbenchmark.** An `Effect` loop over a `Ref`. Not the corpus, not a
  real program, not ADT-heavy code.
- **The tag-tuple claim is measured only as a type-level fact.** That deep ADTs
  produce huge types is demonstrated; that this *costs* what the `Effect` case
  costs is inferred from the same mechanism, not yet measured.
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
3. Measure the tag-tuple cost directly, with a deep `List` fold.
4. Only then decide ADR-0001, with the requirement clear: **non-parametric,
   `Any`-typed fields**.
