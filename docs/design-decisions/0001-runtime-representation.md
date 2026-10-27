# 0001. Runtime representation of PureScript values in Julia

- Status: Accepted; amended 2026-10-26 (ADT and Effect boxing, see the end)
- Date: 2026-06-08

(The decision was made when the backend was first built, 2026-06-05; this
record is a backfill.)

## Context

A CoreFn → Julia code generator must fix, once, how each PureScript value
category is represented as a Julia value. The choice has to satisfy three
constraints simultaneously:

1. **Faithful semantics.** The reference is the JS backend; the differential
   suite holds Jurist to byte-identical output. The representation must make
   that achievable for every category that is not a deliberate divergence.
2. **A clean FFI seam.** Foreign code is hand-written Julia. The mapping must
   be simple enough that a shim author can mirror the real JS foreign module
   without a translation manual.
3. **The motivating force.** Jurist exists to run whole computations on the
   Julia runtime (numerics, the specializing JIT). The representation must not
   impose per-operation interpreter overhead that defeats that purpose.

## Decision

| PureScript | Julia |
|---|---|
| Functions | curried unary closures; application is `(f)(x)(y)` |
| ADT values | tag-tuples: `("Just", x)`, nullary `("Nothing",)` — tag at `[1]`, fields from `[2]` (Julia is 1-based) |
| Newtypes | identity — no runtime wrapper |
| Typeclass dictionaries | `Dict{String,Any}` keyed by member name |
| Records | `Dict{String,Any}`; update via `merge` |
| Arrays | `Any[...]` vectors; the FFI translates the 0-based PS API to 1-based |
| `Effect a` / `ST r a` | zero-argument closure (thunk); running is `f()` |
| Char / String | Julia `Char` / `String` (UTF-8) |
| Int | `Int64` |
| Number | `Float64` |
| Unit / undefined | `nothing` |
| Modules | one Julia `module` per PS module, loaded deps-first by `loader.jl` |

Top-level mutually-recursive value bindings go through a lazy-thunk runtime
(`purejl_runtime.jl`); local recursion uses Julia closure capture.

## Consequences

- The JS foreign convention transfers almost verbatim: curried foreigns are
  chains of unary closures, effectful foreigns are `() -> …` thunks. This is
  what makes the FFI doctrine in [0002](0002-ffi-shim-doctrine.md) cheap.
- `Int` as `Int64` and strings as codepoint-indexed `String` are *upgrades
  along the Julia grain* that diverge from JS int32 / UTF-16 code units. These
  are the deliberate, enumerated entries in the differential suite's
  `KNOWN_DIVERGENCES` (the `INT64-` and `ASTRAL-` families), not accidents.
- ADTs and records are tuples/`Dict`s — a compiler-internal encoding. User and
  library FFI must therefore **not** hardcode that shape; see
  [0002](0002-ffi-shim-doctrine.md). The *primitive* contracts in this table
  (Number↔Float64, Array↔Vector, Effect/ST↔thunk, …) are the stable seam that
  FFI may assume.
- Curried-unary application has a measured cost (~325 ns/iteration of
  curried-Dict glue). This is acceptable for control code and is the explicit
  reason the numeric story keeps hot loops *off* the seam (staged Julia, typed
  handles — see [`../julia-shaped-libraries.md`](../julia-shaped-libraries.md)),
  rather than threading PS closures through Julia inner loops.

## Alternatives considered

- ~~**Uncurried multi-argument functions by default.** Rejected: CoreFn is
  curried, the JS backend is curried, and matching it keeps the differential
  suite honest and the FFI convention shared. Saturated multi-arg calls are
  instead recovered selectively (`Fn`/`EffectFn` via `Data.Function.Uncurried`,
  and the TCO dispatch loop).~~

  > **Superseded in part (2026-10-27) by [0010](0010-saturated-calls-and-inliner.md).**
  > The stated reasons still hold, and 0010 keeps them: a function *value*
  > is still a curried closure, foreigns stay curried, and the change is
  > invisible to the differential suite. What changed is that a call of a
  > known-arity top-level function with enough arguments is now a direct
  > call of its n-ary method. "`App` is a spine, not a saturation guarantee"
  > is true for an unknown head, but not for a top-level lambda chain of
  > arity n applied to at least n arguments.
- **Struct/`@enum` ADTs (the wasm backend's approach).** Rejected for v1:
  tag-tuples need no type pre-declaration pass over the whole program and keep
  the generator simple. The cost is that pattern matching indexes tuples
  rather than dispatching on types; revisit if it ever bounds performance.

  > **Progress (2026-07-31): it now bounds performance, and the trigger is
  > identified.** `tests/purs/passing/TCOCase` builds a 10,000-deep
  > `data Data = One | More Data` and times out at 180 s on **both** lanes
  > (`purejl` and `backend-jl` — so it is the representation, not either code
  > generator). Timing the generated program at reduced depths gives 0.5 / 1.0 /
  > 2.7 / 11.2 / 51.2 s at depth 20 / 50 / 100 / 200 / 400 — about 4.5× per
  > doubling. The structural reason is that Julia tuples are **concretely
  > typed**, so a recursive ADT's *type* nests as deep as its *value*:
  > `typeof` renders as 1,513 / 3,013 / 6,013 characters at depth 100 / 200 /
  > 400, i.e. the type's size is linear in the value's depth. A hand-written
  > build-and-walk of the same shape in plain Julia is much cheaper than the
  > generated program, so the depth-growing type is necessary but not
  > sufficient to explain the whole factor; the remainder is uncharacterised.
  > A struct-per-constructor encoding would give each constructor one fixed
  > type regardless of depth, which is the property tag-tuples lack. This is
  > the revisit trigger this bullet asked for; see
  > [0009](0009-two-implementations.md).
- **Int as Julia `Int` matching the host (32- or 64-bit) or as a wrapped
  32-bit type.** Rejected: `Int64` is the honest Julia integer and the thing
  numeric code wants; the divergence from JS int32 is documented rather than
  emulated (except `Data.Int.Bits` / `Data.Int.pow`, which *do* apply JS
  `ToInt32` because their laws demand it).

## Amendment, 2026-10-26: one type at every depth

**Changed:** ADT values are a single runtime struct, `PSData`, and an
`Effect`/`ST` built by `bind` is boxed in `PSEff`. Both are defined in
`purejl_runtime.jl`.

| PureScript | Julia (amended) |
|---|---|
| ADT values | `PSData(tag, n, f1, f2, f3, rest)`: e.g. `PSData("Just", 1, x, nothing, nothing, ())`. Still indexed tag at `[1]`, fields from `[2]` |
| `Effect a` / `ST r a` | anything callable with no arguments: a bare 0-arg closure (`pure`, `map`, most shims) or a `PSEff` (`bind`) |

**Why.** The revisit trigger in "Alternatives considered" fired twice, and
`docs/PERFORMANCE-FINDING-2026-08-01-type-nesting.md` found the mechanism. A
Julia tuple and a Julia closure are both parametric over what they contain,
so a recursive value's *type* grows with the value: a `Cons` list's type is
as long as the list, and a recursive `Effect` loop's type gains a level per
`bind`. Julia then compiles a fresh specialisation at every size. Both
structs here are **non-parametric with `Any` fields**, which is the property
the finding identified.

**Design choices, each measured** (perf canary, julia 1.12.6, M4 Mini; see the PR):

- **One struct for every constructor, not one per arity.** Per-arity structs
  (`PSData0`…`PSData6`) were *slower*: `fold-list@100` 42 → 66 µs. A
  dispatch site that sees both `Nil` and `Cons` became polymorphic.
- **Three fields inline, the rest in a `Tuple`.** Just, Cons, Tuple and Loop
  are one allocation, not a struct plus a tuple.
- **Only `bind` is boxed.** `pure` and `map` capture a value, not an effect,
  so their types don't nest. Boxing them too cost +50 % on `loop-null` for
  nothing.
- **A closure with `::Any`-declared captures does not erase the type.**
  Julia still parametrises the closure on the captured values (tested), so
  the `PSEff` box is necessary.

**What did not change.** Pattern matching still reads `x[1]` and `x[i+1]`
(`PSData` defines `getindex`/`length`/`==`/`hash`), so generated matchers
and any user FFI that indexes an ADT are unchanged. Running an effect is
still calling it. The tag stays a `String`.

**Cost accepted.** Steady state on `loop-tailrec` (an `Effect` `tailRecM`
loop: several binds per iteration) is about +24 %, `ffi-call` about +6 %.
Everything that recurses over data got faster (`fold-list` 3.3×), and
first-call cost, which is what Julia users actually wait for, fell 13×
across the canary.

**FFI rule this adds.** Don't test `isa Function` or `isa Tuple` on a
PureScript value. Build ADTs through the constructors PureScript passes in
(the JS convention), or `PSData(tag, fields_tuple)`, and run effects by
calling them. The representation canary (`examples/repr-canary`) asserts
the new shapes.
