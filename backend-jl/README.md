# `backend-jl` — the optimizer-consumer lane for Jurist

A PureScript program that consumes
[`purescript-backend-optimizer`](../../purescript-backend-optimizer)'s optimized
IR (`BackendSyntax` / `NeutralExpr`) and lowers it to Julia.

There are **two implementations in this repo on purpose** — see
[ADR-0009](../docs/design-decisions/0009-two-implementations.md). `purejl`
(`../src`, Haskell, raw CoreFn) is the correctness **oracle**; this is the
consumer lane. Correctness claims rest on the oracle, and the method is that
both lanes run the same corpus and are diffed against the same JavaScript
reference.

## Status

```
20/20 green   (17 identical + 3 ledger-only)         ./run_conformance.sh
342/347 = 98.6%   tests/purs/passing @ v0.15.15      purs-corpus/run_corpus.py
```

The oracle lane (`purejl`) scores 341/347 on the same corpus, run the same day
with the same harness. This lane fixes **three** — `3957` and `PartialTCO`
(mutual TCO), `StringEscapes` (lone surrogates) — and regresses **two**, both of
them upstream in the optimizer's CoreFn JSON decoder rather than in this
lowering (`NegativeIntInRange`, `StringEdgeCases`; the same two the Python lane
hit). Three failures are common to both lanes: `2136` (`Int` wrapping — a
representation decision, Gate C9's to settle), `TCOCase` (the tag-tuple ADT
encoding, see [ADR-0001](../docs/design-decisions/0001-runtime-representation.md)'s
2026-07-31 note) and `TCOMutRec` (join points, below). Test-by-test comparison
in [ADR-0009](../docs/design-decisions/0009-two-implementations.md).

## What it does not own

**No runtime, and no foreign shims.** `backend-jl` emits one Julia module per
PureScript module using `purejl`'s naming, so `purejl_runtime.jl` and every
`<Module>_foreign.jl` are produced by `purejl` and copied in unmodified. This is
deliberate and evidence-driven: Gnomon kept two ~2,400-line Go runtimes, they
diverged by two symbols, and only a red CI caught it. Here a fork is not
available, and `bin/conformance.sh` asserts the second copy does not exist.

Three helpers were added to the *shared* runtime for the PrimOps the IR lowers
with no foreign to fall back on — `_int32`, `_zshr`, `_int_div` — holding
exactly the semantics `Data_Int_Bits_foreign` and `Data_EuclideanRing_foreign`
hold for the oracle. One definition each, both lanes. Ordinary `Int` arithmetic
is untouched: Jurist's `Int` is `Int64`
([ADR-0001](../docs/design-decisions/0001-runtime-representation.md)), so only
the bit operations, whose laws demand JS `ToInt32`, wrap.

## Expression-oriented, and why that is the whole story

This is where the port parts company with `backend-py`, and the difference is
not stylistic.

Python's `lambda` takes an *expression*, so an expression-oriented emitter has
to encode blocks as `(lambda: ((x := e), body)[-1])()` — which is what `purepy`
does, and why it needs a lambda-lifting pass to stay under CPython's ~200-deep
parenthesis cap. `backend-py` answered that by emitting **statements**, and paid
for it: an IR scope stopped being a target scope, and four separate
name-collision classes followed (sibling `Let`s at the same de Bruijn level,
top-level bindings sharing module scope, loop dispatchers sharing module scope,
generated names colliding with user identifiers). Closing them took a
module-wide rename pass.

Julia has no such tension. `let x = v; body end` and `if c; a; else; b; end` are
**both scoped blocks and expressions**. So a `Let` is a `let`, a `Branch` is an
`if`/`elseif` chain, and every IR scope is a real Julia scope — the property
`backend-go` buys with an IIFE per binding, here for free. There is no statement
buffer, no lambda lifting, no rename pass, and no `Env.locals` map: the
optimizer's within-a-scope uniqueness of de Bruijn levels is exactly the
guarantee the target needs.

The one place statements are unavoidable is a TCO loop body, which has to
`return` a continue/stop signal. That walk (`genLoopStmts`) is the only
statement-mode code in the emitter, and it uses `let` for its bindings so the
scoping guarantee holds there too.

## Representation

`purejl`'s, because the foreigns are shared — and **1-based throughout**, which
is the systematic difference from the Python lane:

| | |
|---|---|
| ADT | tag-tuple `("Just", x)`; tag at `[1]`, field *i* at `[i+2]` |
| Record / dictionary | `Dict{String,Any}`, updated with `Base.merge` |
| Array | `Any[]` vector, indexed from 1 while the PureScript API is 0-based |
| `Effect a` | zero-argument closure |
| `Ref` | one-element `Any[]` |
| Function | curried unary closure, `(f)(x)(y)` |
| `Int` / `Number` | `Int64` / `Float64` |
| String append | `*` |

## Tail calls

Self-recursive and directly mutually-recursive groups lower to an inline `while`
over a tagged pair — `purejl`'s own
[ADR-0003](../docs/design-decisions/0003-tco-trampoline.md) shape, so this lane
needs **no runtime support at all** for TCO. The function-call-per-iteration is
load-bearing: mutating the loop parameters in place would box and share them
across iterations, so any closure built in the body would capture the last
iteration's bindings.

Mutual recursion is where this lane goes past the oracle. `purejl` explicitly
does not trampoline it (ADR-0003 defers it, matching the JS backend's posture);
here a group of more than one member gets a leading branch register and shares
one dispatch loop, which is a codegen change only.

**Join points remain the open frontier.** `TCOMutRec`'s `tco1` defines `g` in a
`where` inside `f`, so the optimizer marks each a separate self-loop and the
cross-calls stay stack calls. The optimizer already computes what is needed
(`TcoRole.joins`); this lane reads only `isLoop`. The fitting shape is already
built — a join point becomes another member of the same dispatch group — but it
is not wired up.

## Usage

```bash
spago build

# emit Julia for a whole corefn output directory, pruned to one entry point
node run.mjs --corefn-dir ../test-suite/output --output-dir out --main Test.ADTs

# the runtime and the foreigns come from the oracle lane
cp ../test-suite/output-jl/purejl_runtime.jl out/
cp ../test-suite/output-jl/*_foreign.jl out/

julia out/main.jl
```

`--main` prunes: every binding unreachable from that module's `main` is dropped,
along with any module left empty. `loader.jl` then `include`s what survives in
dependency order, and `main.jl` runs it.

## Conformance

```bash
./run_conformance.sh                # builds purejl first, then this lane
./run_conformance.sh --skip-purejl  # reuse ../test-suite/output-jl
```

The `Test.*` corpus is shared with `purepy`, Pythia and Gnomon — one family
conformance kit, per-backend divergence ledgers.

## Layout

- `src/Main.purs` — CLI, entry reachability, module assembly, `loader.jl` and
  `main.jl`
- `src/PureScript/Backend/Optimizer/Codegen/Julia.purs` — the emitter
- `src/PureScript/Backend/Optimizer/Codegen/Julia/Builder.purs` — the build
  driver, a verbatim port of backend-es's (nothing ES-specific in it)
- `src/PureScript/Backend/Optimizer/Reachability.purs` — entry pruning, shared
  verbatim with `backend-go` and `backend-py`, and belonging upstream
