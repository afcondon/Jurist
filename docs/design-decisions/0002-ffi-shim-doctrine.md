# 0002. FFI shim doctrine: real-JS foreigns and representation independence

- Status: Accepted
- Date: 2026-06-08

## Context

A PureScript module with `foreign import`s needs a Julia counterpart
(`Module_Name_foreign.jl`). Two failure modes have to be designed out:

1. **Guessing semantics.** A shim author who reconstructs what a foreign
   "should" do — or who copies another backend's shim — gets the edge cases
   wrong (empty patterns, out-of-range indices, `NaN`/`-0.0`, the sign
   convention a PS caller re-inverts). The reference JS foreign modules in
   `.spago/p/` are the ground truth.
2. **Leaking the representation.** [0001](0001-runtime-representation.md)
   encodes ADTs as tag-tuples and records as `Dict{String,Any}`. A shim that
   writes `("Nothing",)` or `Dict{String,Any}("l"=>…)` by hand couples user
   code to a compiler-internal encoding that may change, and undercuts the
   uniformity that makes a PS-skinned polyglot system worth building.

There is a tension to resolve with (2): Jurist's whole purpose is to complete
a computation in one go on the Julia runtime. If producing a PureScript
`Maybe`/record result forced a round-trip back into a PS interpreter, the rule
would fight the motivating force.

## Decision

**Read the real JS foreign; mirror its exact semantics.** Translate only the
indexing base (PS 0-based → Julia 1-based) and `Base.`-qualify any name the
module shadows. Saturated `Fn`/`EffectFn` foreigns are genuine multi-argument
Julia functions.

**Do not depend on — or force a user to depend on — the runtime
representation of a PureScript ADT or record.** Use the JS backend's own
pattern (`Data.Array.indexImpl(just, nothing, …)`):

- **Producing** a PS ADT/record in a shim → have the PS side hand the
  constructor / record-builder *in* as an argument and call it.
  `cholesky = choleskyImpl Just Nothing`;
  `lu = luImpl (\l u p -> { l, u, p })`.
- **Consuming** a PS ADT in a shim → take the *eliminator* (`maybe`, `either`)
  in; never destructure the tuple.
- Only the **primitive contracts** of [0001](0001-runtime-representation.md)
  may be assumed: Number↔Float64, Int↔Int64, String↔String, Char↔Char,
  Array↔Vector, Effect/ST↔nullary thunk, Unit↔`nothing`.

**Exception — the core library shims.** The built-in shims for `Data.Array`,
`Data.Maybe`, `Data.String`, … are co-maintained with the code generator and
*are* the backend's standard library; they legitimately encode the
representation. The representation-independence rule governs **user, example,
and Julia-shaped-library** shims.

## Consequences

- The tension dissolves: after compilation `Just`, `Nothing`, and a
  record-builder lambda are *ordinary Julia closures living in the Julia
  runtime* (`Just = (v0) -> ("Just", v0)` in the generated `Data_Maybe.jl`).
  Julia runs the whole computation and calls the handed-in closure to assemble
  the result — no interpreter round-trip, no re-boxing across the seam. The
  doctrine strengthens to **"constructors across, handles back."**
- A change to the ADT/record encoding (e.g. a future move to struct ADTs)
  breaks only the co-maintained core shims, never user code.
- Verified in `examples/st-number-vector` (`Data.STMatrix`'s `cholesky`
  returning `Maybe` and `lu` returning a record); the indefinite-matrix case
  yields `Nothing` with no hand-written tag-tuple anywhere in the shim.

## Residual dependency: acknowledged and pinned

"Constructors across" decouples user-shim **authoring** from the encoding —
if ADTs became structs, `Just`/`Nothing` would recompile to build structs and
`choleskyImpl Just Nothing` would keep working untouched. But the port as a
whole stays **irreducibly bound** to the codegen's translation of `Maybe` (and
every ADT/record):

- all generated pattern-matching is written against it (`__v__[1] == "Just"`);
- the co-maintained core shims encode it by exception;
- even the mild assumption that `Nothing` is a first-class handable value and
  `Just` a callable is a representation assumption at the FFI boundary.

This cannot be designed away **given the efficiency goal**: the only
representation-agnostic way to *consume* an ADT inside a shim is to pass
eliminators (`maybe`, `either`), which reintroduces a PureScript closure per
element across the seam — the callback anti-pattern that defeats the entire
reason for compiling to Julia. So the honest posture is *acknowledge and pin*,
not eliminate.

**The pin is a representation canary** (`examples/repr-canary`): a white-box
guard that hands compiled PS values to a Julia shim asserting their raw shape
(`Just x` is `("Just", x)`, `Nothing` is `("Nothing",)`, records are
`Dict{String,Any}`, newtypes are erased, `Effect` is a 0-arg thunk, `Array` is
a `Vector`) and `Base.error`s on any drift. Verified: a deliberately corrupted
expectation aborts the run with a non-zero exit and a `REPRESENTATION DRIFT`
message. If `purejl` ever changes an encoding, this fails first and loudly,
forcing a conscious update of the co-maintained shims rather than letting
hand-written FFI break silently. It belongs in the CI conformance lane.

## Alternatives considered

- **Let shims construct tag-tuples / `Dict`s directly.** Rejected: brittle and
  representation-leaking (see Context 2). Acceptable only inside the
  co-maintained core library shims.
- **A generated marshalling layer that reconstructs foreign signatures** (the
  wasm backend's ADR-0016 approach, driven by `externs.cbor`). Heavier
  machinery; Jurist's curried-closure representation makes the
  hand-it-the-constructor pattern sufficient without it. Revisit if the FFI
  surface grows beyond what manual shims comfortably cover.
