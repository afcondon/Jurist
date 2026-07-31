# 0001. Runtime representation of PureScript values in Julia

- Status: Accepted
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

- **Uncurried multi-argument functions by default.** Rejected: CoreFn is
  curried, the JS backend is curried, and matching it keeps the differential
  suite honest and the FFI convention shared. Saturated multi-arg calls are
  instead recovered selectively (`Fn`/`EffectFn` via `Data.Function.Uncurried`,
  and the TCO dispatch loop).
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
