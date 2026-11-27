# 0003. Tail-call optimization via self-tail-call dispatch loops

- Status: Accepted; amended 2026-11-27 (how a step says it is done, see the end)
- Date: 2026-06-08

(Decision made when TCO was implemented, 2026-06-05; this is a backfill.)

## Context

PureScript programs rely on tail-call optimization for iteration — the JS
backend's optimizer rewrites self-tail-calls into `while` loops, so idiomatic
recursive loops run in constant stack. Julia **does not guarantee** TCO: a
self-recursive function that bottoms out via the call stack overflows on deep
input. The backend must reproduce the JS optimizer's guarantee, or it cannot
run ordinary PureScript.

## Decision

Mirror `purs`'s JS optimizer. A binding whose self-references are **all
fully-saturated tail calls** compiles to a dispatch loop driven by a tagged
pair — `(1, newargs)` to continue, `(0, result)` to stop:

```julia
sumTo = (function ();
    function _tco_loop(acc, n); …; end          # returns (1, (acc',n')) | (0, result)
    (acc) -> (n) -> (begin
        _tco_r = (1, (acc, n,))
        while _tco_r[1] == 1; _tco_r = _tco_loop(_tco_r[2]...); end
        _tco_r[2]
    end))
end)()
```

> **Note, 2026-11-19.** This listing is the shape as first built, and it is
> still the shape of a local loop. A top-level function is no longer wrapped
> this way: since [ADR-0010](0010-saturated-calls-and-inliner.md) its step
> function is the top-level `_ps_tco_<name>`, and the `while` lives in the
> saturated method `_ps_sat_<name>`. The decision is unchanged.

The **function-call-per-iteration** shape is deliberate, not an oversight:
closures created in the loop body capture the per-iteration bindings, and
in-place mutation of the loop parameters would box and *share* them across
iterations (the classic loop-variable-capture bug). A fresh call per iteration
gives each its own bindings.

Applies at the top level and to local `go`-style loops. **Mutual recursion is
not trampolined** — it matches the JS backend, where `MonadRec` /
`Control.Monad.Rec.Class` is the idiom for unbounded non-self recursion.

## Consequences

- Self-recursive tail loops run in constant stack; verified to 10⁸ iterations.
- Unbounded *mutual* recursion can still overflow the Julia stack. This is a
  documented v1 limitation with an in-language escape hatch (`MonadRec`),
  identical to the JS backend's posture — so it is a parity, not a regression.
- A full mutual-recursion trampoline is a tracked frontier (it is a larger
  code-generator change; see the README's limitations and a future ADR).

> **Progress (2026-07-31):** the frontier is now half-closed, in the *other*
> lane. `backend-jl` ([0009](0009-two-implementations.md)) emits this same
> dispatch-loop shape, and for a group of more than one member adds a leading
> branch register so the members share one loop — so DIRECT mutual tail
> recursion trampolines there. It needed no runtime change: the `while` is the
> runtime. What still escapes both lanes is a *join point* — a member defined in
> a `where` nested inside another, which the optimizer marks as its own
> self-loop (`TCOMutRec`'s `tco1`). `purejl` itself is unchanged; this note
> records that the decision above is now a statement about the oracle lane
> rather than about Jurist as a whole.

## Alternatives considered

- **In-place mutation of the loop parameters** (the most obvious "while loop"
  lowering). Rejected: shares captured bindings across iterations, miscompiling
  any loop body that closes over its parameters.
- **A full trampoline including mutual recursion now.** Deferred: bigger
  codegen surface, and the JS backend doesn't do it either — `MonadRec` is the
  accepted idiom, so matching it keeps the differential suite honest.
- **Rely on Julia's own tail calls.** Impossible: Julia gives no TCO guarantee.

## Amendment, 2026-11-27: done is a type, not a tag

**Changed:** a step function returns `_TcoDone(result)` when the loop is
finished and a plain tuple of the next arguments when it is not. The driver
is

```julia
_tco_r = _tco_loop(acc, n)
while !(_tco_r isa _TcoDone); _tco_r = _tco_loop(_tco_r...); end
_tco_r.value
```

in both lanes. `_TcoDone` is a one-field struct in `purejl_runtime.jl`.

**What did not change:** the decision above. There is still one call of the
step function per iteration, so a closure made in a loop body still
captures that iteration's own bindings, and the rejected alternative
(assigning to the loop's parameters in place) is still rejected.

**Why.** The tagged pair was `(1, (args...,))` or `(0, result)`, and the
driver splatted its second slot into the next call. That slot's type is the
union of "a tuple of arguments" and "whatever the result is", and Julia
cannot narrow a union by the *value* of a neighbouring slot. When the
result was an `Int` the splat was legal either way (a number iterates), so
it could not be resolved at compile time and every iteration went through a
dynamic call. `isa` narrows a union by type, so inside the `while` the
compiler knows it holds the argument tuple.

**Measured** (perf canary, M4 Mini, julia 1.12.6; steady state):

| shape | before | after | Node |
|---|---:|---:|---:|
| `record-numeric` @ 100,000, `jl` | 5,369 µs | 241 µs | 759 µs |
| `record-numeric` @ 100,000, `backend-jl` | 5,322 µs | 238 µs | 759 µs |
| `fold-list` @ 100, `jl` | 25.3 µs | 8.0 µs | 8.5 µs |
| `fold-list` @ 100, `backend-jl` | 17.4 µs | 7.5 µs | 8.5 µs |

Speed index against JS: `jl` 4.41 to 3.42, `backend-jl` 1.24 to 0.91 (the
re-recorded baseline). First-call index: `jl` 48.6 to 41.6, `backend-jl`
28.7 to 21.3. Start-up did not move.

`Atlas.Bench` (see `docs/PERFORMANCE-FINDING-2026-07-30.md`), marginal cost
of 2,000,000 RK4 steps, same checksum: 171 ms before, **111 ms** after. The
hand-written kernel measured 111 ms in the same run and Node 155 ms.
`loop-tailrec` did not move: that shape is `tailRecM`, which loops inside
its shim and never reaches this driver.

Found by hand-editing the generated loop three ways: the same step function
with the typed return ran at 2.4 ns an iteration, the same as assigning in
place, against 51 to 62 ns for the tagged pair.

**The optimizer lane's mutual-recursion groups** pass a register per local,
and a slot a branch has not written is `nothing`. So the argument tuple's
type can differ from branch to branch, and a group with many branches may
exceed what Julia will union-split. That is correct and no slower than
before, but it is not measured.

