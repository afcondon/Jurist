# 0003. Tail-call optimization via self-tail-call dispatch loops

- Status: Accepted
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
