# 0008. Same-seed differential fuzzing

- Status: Proposed
- Date: 2026-06-08

## Context

The differential suite ([0004](0004-differential-conformance.md)) is a *fixed*
corpus of hand-written `Test.*` modules. It proves parity on the cases someone
thought to write. Generative testing would explore far more of the value space
and grow the divergence ledger automatically — turning "422/426 on a fixed
suite" into continuously machine-checked parity, the credibility backbone for
putting a real demo in front of the backend.

The hard prerequisite is **shared-PRNG determinism**: same-seed differential
fuzzing only works if `purescript-lcg` (under `purescript-quickcheck`) produces
*identical seed sequences* on JS and on Julia. That is not obvious — the LCG
does `Int` modular arithmetic, and Jurist's `Int` is `Int64` while JS is
int32-wrapped ([0001](0001-runtime-representation.md)). If the multiply
overflowed differently, the sequences would diverge and the approach would
collapse.

## Decision (Proposed)

Build a same-seed differential fuzzing lane: compile `purescript-quickcheck`
generators to **both** backends, drive them with the same seed, diff the
generated values, and on a mismatch **shrink** to a minimal counterexample that
is then triaged into `KNOWN_DIVERGENCES` (a real divergence) or fixed (a bug).

Resolve the prerequisite by shimming `Random.LCG` for Julia and proving
determinism. The arithmetic is expected to *agree*: `purescript-lcg` was
designed so the LCG's intermediate product (`48271 * n`, up to ~10¹⁴) stays
below 2⁵³, and its JS foreign does the multiply in `Number` (double) space —
so a faithful Julia `Int64` shim computes the *same* exact integer despite the
int32-vs-Int64 divergence that affects other code. To be **verified** by a
determinism probe before the lane is built; `Random.LCG` likely becomes a
built-in shim so the whole QuickCheck ecosystem works on the backend.

## Consequences (anticipated)

- Unlocks the entire `purescript-quickcheck` ecosystem on Jurist, not just
  fuzzing.
- Upgrades `KNOWN_DIVERGENCES` from named cases toward enforced *predicates*
  (guarded observational equivalence): a generated value either matches or
  falls under a documented divergence class, checked both ways.
- Open risk, the reason this is Proposed not Accepted: the RNG-determinism
  probe is unrun (it was started, then deferred in favour of the ADR/CI
  professionalisation pass).

## Alternatives considered

- **Backend-specific generators.** Rejected: defeats the purpose — without a
  shared seed sequence there is no same-input differential comparison.
- **TLA+ / model checking for value semantics.** Wrong tool: TLA+ is for the
  *temporal* seam (the browser ↔ BEAM ↔ Julia protocol), not for differential
  value semantics, which this mechanism covers directly.
- **Port `purs`'s own test corpus instead.** Complementary (see
  [0004](0004-differential-conformance.md)), not a substitute — a fixed
  conformance kit does not *generate* new counterexamples.
