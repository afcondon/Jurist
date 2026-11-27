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
- **Fields are held in label order**, whatever order they were written in,
  so `{ x, y }` and `{ y, x }` are one Julia type. The field expressions are
  still evaluated in source order.
- **A record literal at module top level** is `_ps_rec_dyn((:x, :y), (a,
  b))` instead. See "Start-up" below.
- **A field read** is `_ps_get(r, :x, "x")`. It takes the label twice
  because a record may still be a `Dict` (below): the Symbol reads a
  `PSRecord`, the String reads a `Dict`.
- **Update** is `_ps_update(r, (; x = a))`, which keeps the other fields.
- **`PSRecord` is an `AbstractDict{String,Any}`.** A shim or a user foreign
  that reads `rec["x"]`, asks `haskey`, or iterates works unchanged.
- **It is immutable.** Assigning to one, or deleting from one, is an error
  whose message says so and says what to do: `copy` returns a mutable
  `Dict{String,Any}`.
- **A `Dict{String,Any}` is still a valid record.** `_ps_get` and
  `_ps_update` accept one. That is what a foreign written before this
  record returns, and what a foreign that copies and mutates returns.
- **The core shims keep a record a `PSRecord`.** `Record.Unsafe`,
  `Record.Builder` and `Record.Unsafe.Union` are built on `_rec_set`,
  `_rec_delete` and `_rec_union`, which take a label known only at run time
  and return a `PSRecord` when given one. `Record.Builder`'s `copyRecord` is
  the identity: there is nothing to protect from mutation.

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

### Start-up

`_ps_rec` is compiled once for every distinct tuple of field types, and a
Julia closure has a type of its own. So a table of records that each hold a
function, or a module's typeclass instances, cost one compilation per
literal: 3.0 ms each, against 0.35 ms for the `Dict` they replaced
(measured, julia 1.12.6). With every literal on that path the optimizer
lane's start-up rose from 285 to 351 ms on the perf corpus.

A literal at module top level runs once, at load, and nothing there is
inferred: the binding it initialises is an untyped global. So both
generators emit `_ps_rec_dyn` for a record literal that is the value of a
top-level binding, an element of a top-level array literal, or (oracle
lane) the argument of the constructor that wraps a typeclass instance.
`_ps_rec_dyn` does the sorting and the widening on the values and allocates
the two structs through `jl_new_structv`, compiling nothing for the shape:
0.33 ms per literal. The record it returns has exactly the type `_ps_rec`
gives, which the representation canary pins (`repr-record-toplevel`).

Start-up on the perf corpus, M4 Mini, julia 1.12.6:

| | main | this record |
|---|---:|---:|
| optimizer lane | 279 to 287 ms | 309 to 310 ms |
| oracle lane | 8,599 to 8,704 ms | 6,501 to 6,592 ms |

What is left on the optimizer lane is a fixed cost of about 26 ms: Julia
lowering the runtime's larger definitions when `purejl_runtime.jl` is
included (measured by including the runtime alone, with and without the
record block). It does not grow with the program. Removing it would mean
shipping the runtime as a precompiled Julia package, which is a different
decision.

### `@generated`

`_ps_rec` is a `@generated` function, so the sorting and the widening
happen once per shape at compile time. Two things were checked, because a
generated function is the usual suspect for both:

- Written without it, through `Base.@assume_effects :foldable`, the result
  infers just as well and compiles 3.6 times slower per shape (6.3 ms
  against 1.8 ms).
- `juliac --trim=safe` (julia 1.12.6) accepts it: a numeric loop over
  records built and ran as a 1.2 MB executable. The rest of `purejl`'s
  output is not trimmable, so this shows only that the record is not what
  stands in the way.

Its body uses plain loops over plain vectors. Written with `sortperm` and
comprehensions it added about 100 ms to start-up, because that body is
compiled when the first record is built.

## Consequences

- A record of numbers is plain bits: no allocation, fields in registers.
  This is the case the Julia backend exists for.
- The perf canary has a shape for it, `record-numeric`: a pure loop whose
  state is a record of Numbers. At n = 100,000 it went from 158 ms to 5.4 ms
  on the oracle lane and from 73 ms to 5.3 ms on the optimizer lane, and
  the drift gate now holds it.
- That shape is still about 7 times slower than Node (0.78 ms). Records are
  no longer the reason. The tail-call loop is the suspect: it returns a
  differently shaped tuple on its last iteration. Unconfirmed, and not
  addressed here.
- A foreign that mutates a record in place now fails, with a message. None
  in this repo did except `Record.Builder`'s shim, which is rewritten.
- A record that came back from a foreign as a `Dict` reads as slowly as
  before. Nothing re-freezes it.
- A record coerced to a `Foreign.Object` is still read in sorted key order
  ([0011](0011-foreign-object-and-json.md)), and since a `PSRecord` holds
  its fields sorted, it has no source order to offer either.
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
