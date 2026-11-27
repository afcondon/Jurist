# 0012. Records are `PSRecord`, a NamedTuple Julia can see through

- Status: Proposed
- Date: 2026-11-27
- Supersedes in part: [0001](0001-runtime-representation.md), the "Records"
  and "Typeclass dictionaries" rows.

## Context

[0001](0001-runtime-representation.md) made a record a `Dict{String,Any}`.
`docs/PERFORMANCE-FINDING-2026-07-30.md` measured what that costs: the same
`Atlas.Dynamics` ran about 70 times slower on Julia than on Node. Saturated
calls ([0010](0010-saturated-calls-and-inliner.md)) brought that to 27 times.

The finding's prescription was to emit concrete types where CoreFn knows
them. An experiment on 2026-11-27 showed that is not needed. Julia
specialises a method on the types of the values it is called with, so it
does not need annotations. What it needs is a representation it can infer
*through*, and a `Dict{String,Any}` is the one place it cannot: every field
read is a hash lookup that returns `Any`.

The experiment took `purejl`'s real output for `Atlas.Bench` and rewrote
two files mechanically, `Dict{String,Any}("x" => a)` to `(; x = a)` and
`s["x"]` to `s.x`, changing nothing else. Marginal cost of 2,000,000 RK4
steps (large run minus small run, best of three, julia 1.13.3, M4 Mini), all
printing the same checksum:

| | ms | against Node |
|---|---:|---:|
| hand-written kernel (`native/kernel_fixed.jl`) | 64 | 0.37× |
| hand translation with typed structs | 83 | 0.48× |
| `purejl` output, records as NamedTuples | 160 | 0.92× |
| Node (stock `purs`) | 174 | 1× |
| `purejl` output, records as `Dict` | 4,783 | 27× |

## Decision

| PureScript | Julia |
|---|---|
| Records | `PSRecord{NT}`, an immutable struct holding one NamedTuple |
| Typeclass dictionaries | the same: CoreFn builds them as record literals |

- **Construction** is `_ps_rec((; x = a, y = b))`. A label that is not a
  plain identifier is written `:var"content-type"`, and one that cannot be
  written as a Symbol literal goes through `Base.Symbol("…")`.
- **A field read** is `_ps_get(r, :x, "x")`. It takes the label twice
  because a record may still be a `Dict` (below): the Symbol reads a
  `PSRecord`, the String reads a `Dict`.
- **Update** is `_ps_update(r, (; x = a))`, which keeps the other fields.
- **`PSRecord` is an `AbstractDict{String,Any}`.** A shim or a user foreign
  that reads `rec["x"]`, asks `haskey`, or iterates works unchanged. It has
  no `setindex!`: `copy` returns a `Dict{String,Any}`, so the shims that
  copy and then mutate (`Record.Unsafe`, `Record.Builder`) work unchanged
  and hand back a `Dict`.
- **A `Dict{String,Any}` is still a valid record.** `_ps_get` and
  `_ps_update` accept one. That is what a foreign written before this
  record returns, and what the copy-and-mutate shims return.

### Which fields keep their type

A field keeps its concrete type only if that type is `Float64`, `Int64`,
`Bool`, `Char`, `String`, or a `PSRecord` that is itself plain bits. Every
other field is `Any`, as a `Dict`'s values were.

A NamedTuple is parametric over its fields' types, which is the property
`docs/PERFORMANCE-FINDING-2026-08-01-type-nesting.md` warns against: a type
that grows with the value makes Julia compile a new specialisation at every
depth. Two shapes would do that if every field kept its type:

- a record holding a closure that captured another record
  (`newtype Stream a = Stream { head :: a, tail :: Unit -> Stream a }`);
- a chain of records through `Nullable`, whose representation is the value
  itself or `nothing`.

Under the rule, a closure field is `Any`, and so is `nothing`, so a record
that holds either is not plain bits and is `Any` in the record that holds
it. The runtime tests pin both: a chain of depth 1 and of depth 50 have the
same type.

The rule also gives a typeclass dictionary one type per class shape, not one
per instance, because its members are closures.

## Consequences

- A record of numbers is plain bits: no allocation, fields in registers.
  This is the case the Julia backend exists for.
- Field order is now part of a record's Julia type. `{ x: 1, y: 2 }` and
  `{ y: 2, x: 1 }` are different types that behave the same.
- `_ps_rec` is a `@generated` function, compiled once per record shape.
- A record that came back from `Record.Builder` or an older foreign is a
  `Dict`, and reads of it are as slow as before. Nothing re-freezes it.
- A record coerced to a `Foreign.Object` is still read in sorted key order
  ([0011](0011-foreign-object-and-json.md)). A `PSRecord` does know its
  source order, so that divergence could now be closed. It is not closed
  here.
- User foreigns that *build* a record as a `Dict` keep working. Ones that
  test `rec isa Dict` do not, and none in this repo does.

## Alternatives considered

- **A bare NamedTuple.** Reading `rec["x"]` on one would need methods on
  `Base` types this project does not own. The wrapper costs nothing at run
  time and makes every existing reader work.
- **A struct per record type**, as a monomorphising compiler would declare.
  It needs the record's type, which CoreFn does not carry. It measured 83 ms
  against this record's 160 ms on the benchmark above, so about half the
  remaining distance to hand-written Julia is still there for a backend
  that has types.
- **Keeping every field's type.** Faster for a record of closures, and
  wrong for the reason above.
