# 0010. Saturated calls and the purs inliner set

- Status: Accepted
- Date: 2026-10-27
- Supersedes: in part, the "uncurried multi-argument functions … Rejected"
  alternative of [0001](0001-runtime-representation.md). A function *value* is
  still a curried closure.
- Cross-backend: review X1 (`purescript-backends/REVIEW-2026-10.md`), the same
  decision in Gnomon (its ADR-0009) and Pythia (its ADR-0004).

## Context

0001 rejected uncurried functions by default because CoreFn and the JS
backend are curried, and because matching them keeps the differential suite
honest and the FFI convention shared. Those reasons stand. But they never
required that every *call* be curried. A top-level binding defined as an
n-deep lambda chain and applied to at least n arguments is a saturated call by
construction, and purerl has always emitted `f/n` for it. "`App` is a spine,
not a saturation guarantee" is true only for an unknown head.

On Julia the curried form costs more than allocations. A top-level `f = (a)
-> (b) -> …` is a non-`const` global, so a call through it is dynamically
dispatched and opaque to inference. A named method is a `const` binding that
Julia infers through.

Andrew's framing (brief `BRIEF-x1-saturated-calls.md`): if PureScript is a
thin layer over robust runtimes, optimising calls is worth an extra pass, and
where the JS world has a mechanism we should do the same or something
analogous.

## Decision

**Both lanes, saturated calls.** A top-level `f = \p1 .. pn -> body` emits a
method `_ps_sat_f(p1, .., pn) = body` and `f` as a curried wrapper over it. A
call with k ≥ n arguments becomes `_ps_sat_f(a1, .., an)`, across modules
`_psmod_M._ps_sat_f(..)`, with the other k − n applied curried.

- A self-tail-recursive binding keeps 0003's dispatch loop, now as a named
  function `_ps_tco_f`, entered from the method.
- In `purejl`, a recursive *function* no longer goes through `_runtime_lazy`:
  a method resolves globals when it is called. *Values* in a recursive group
  are still thunked, as before.
- In `backend-jl`, a binding in a lazily initialised group stays curried.
- Foreigns are not declarations, so they never enter the arity map, and the
  FFI convention is unchanged.

**`purejl` only, the purs inliner set** (`CoreImp/Optimizer/Inliner.hs`).
`backend-jl` already gets these from purescript-backend-optimizer's IR
(`UncurriedApp`, typed `PrimOp`s, `CtorSaturated`):

- `runFnN f a..` is `f(a..)`; `mkFnN (\a.. -> e)` is an n-ary closure;
  `runEffectFnN` / `mkEffectFnN` and the `ST` forms likewise.
- Primitive ops through a known dictionary become Julia operators, looking
  through the module-level aliases CoreFn floats out (`negate =
  Data.Ring.negate ringNumber`), as purs's "expander" does. `append` on
  `String` is `*`, `unsafeIndex` is 1-based, and `Data.Int.Bits` covers
  `and`/`or`/`xor`. Each means what the `*_foreign.jl` shim it bypasses
  means.
- Saturated constructors are built in place: `PSData(..)`, a `Dict`, or the
  argument itself for a newtype.

**Generated names.** The new methods live in `_ps_`, the namespace
`backend-jl` already reserves. `purejl` did not escape it, so the two lanes
mangled an identifier beginning `_ps_` differently. `purejl` now escapes it
exactly as `backend-jl` does.

## Consequences

- NEGZERO is closed on both lanes: seven entries went STALE and were deleted
  with their cause. `negate` on `Number` is unary minus, as on JS; and
  `backend-jl` printed a folded `-0.0` literal through `show`, which gives
  `"0.0"`, and now writes `(-0.0)`.
- Generated code is about 21 % larger by lines. `purejl` takes as long as
  before.
- A method is compiled per concrete argument types, so the risk on Julia
  was more compilation, which the first-call gate holds to 1.25×. It went
  the other way: on the Mac Mini, `jl`'s first-call index fell from 65–66×
  JS to 50–60×, and start-up stayed at about 10.5 s. Steady state is where
  the change is large: the speed index went from 7.4× JS to 4.1× (numbers in
  the PR).
- Only top-level bindings are saturated. A local `let` function, and a call
  through an unknown dictionary, stay curried.
