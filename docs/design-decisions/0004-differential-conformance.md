# 0004. The differential suite as conformance mechanism

- Status: Accepted
- Date: 2026-06-08

(Decision made when the suite was built, 2026-06-06; this is a backfill.)

## Context

A from-scratch backend needs *evidence* that it matches the reference, not a
hope. "Jurist matches JS semantics" has to be a falsifiable, machine-checked
claim — and the places it deliberately does *not* match must be a finite,
named set rather than an open worry. This is also the project's headline
artifact: the harmonized-semantics thesis stands or falls on the divergence
set being enumerable.

## Decision

Compile the same `Test.*` modules **once** with `purs --codegen corefn,js`,
run each module on Node **and** on Julia (via `purejl`), and diff every
`TEST <name>: <value>` line. Byte-identical output is a pass.

- A curated `KNOWN_DIVERGENCES` set, keyed by `(module, test-name)` and
  prefixed by reason (`ASTRAL-` for UTF-16-vs-codepoint, `INT64-` for
  int32-wrap-vs-Int64), records each deliberate divergence **with the JS value
  shown** next to the Julia one. These are reported but do not fail the run.
- Test modules are **foreign-free** (differential testing requires every
  module to run on both backends; user FFI stays out — the seam demos live in
  `examples/` instead).
- The runner (`test-suite/run_tests.py`) is stdlib-only with a CI-able exit
  code: 0 iff no *unexpected* divergence and no module-level error.

## Consequences

- 422/426 byte-identical; 4 documented divergences; 0 failures. This is the
  artifact that backs the backend's "strong claims".
- The suite has already paid for itself — it caught an inverted length
  tiebreak in `ordArrayImpl` (prefix-equal arrays compared backwards, because
  the PS caller re-inverts the foreign's sign convention).
- `KNOWN_DIVERGENCES` is the **divergence ledger**: it turns divergence from an
  unbounded liability into a finite, enumerated, machine-checked list — exactly
  the property the polyglot thesis needs.
- The suite is **black-box** (it compares printed values), so it cannot see a
  change in the *runtime representation* that prints the same. That gap is
  covered by the separate white-box representation canary (see
  [0002](0002-ffi-shim-doctrine.md)).

## Alternatives considered

- **Port `purs`'s own test corpus as the conformance kit.** A strong future
  addition (it is the language's own definition of correct), but heavier to
  wire up; the focused differential modules came first.
- **Property / fuzz testing.** Complementary, not a replacement — the
  same-seed differential fuzzing frontier ([0008](0008-differential-fuzzing.md))
  builds *on* this mechanism.
- **Manual spot-checks.** Rejected: not falsifiable, not CI-able, not evidence.
