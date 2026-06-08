# 0005. Reproducing JS `Number.prototype.toString` formatting

- Status: Accepted
- Date: 2026-06-08

(Decision made 2026-06-06; this is a backfill.)

## Context

`show` for `Number` is observable, so the differential suite ([0004](0004-differential-conformance.md))
holds it to byte-identical output against JS. But JS's `Number → String` is a
specific algorithm that Julia's `string(::Float64)` does not reproduce: a
decimal notation only within `1e-6 ≤ |n| < 1e21`, exponential notation with
`e+` / `e-` outside that window, and a `.0` suffix for integer-valued doubles.
Julia chooses different boundaries and a different exponent style. Leaving this
to Julia's printer breaks parity on common magnitudes (`1e21`, `1e-7`, …).

## Decision

Reimplement the JS placement algorithm as `_js_number_string` in the shared
`PurejlRuntime` module, exported alongside `_runtime_lazy` and imported by
every generated module header. Both `showNumberImpl` and the
`Data.Number.Format` shim route through it, so there is a single source of
truth for the formatting.

## Consequences

- All 18 formatting edge tests pass identically to JS: the `1e21` and `1e-7`
  notation boundaries, `1e10` / `1e20`, max/min double, and `-0.0`.
- Representation-level helpers like this belong in `PurejlRuntime` rather than
  being duplicated per shim — `PurejlRuntime` is the home for "things every
  module needs to match the reference".
- `toFixed` / `toPrecision` tie-rounding still diverges in the exact-tie case
  (C `printf` half-even vs JS half-away-from-zero); non-tie cases agree. This
  is documented in the `Data.Number.Format` shim header rather than hidden.

## Alternatives considered

- **Julia `Printf` / `string`.** Rejected: wrong notation boundaries and
  exponent style — the whole reason this ADR exists.
- **Call a Ryu/Grisu shortest-float routine directly.** Julia already uses Ryu
  internally, but with its own *formatting policy*; the divergence is in the
  policy (where to switch to exponential, the `.0` suffix), not the digit
  generation, so a faithful policy reimplementation is what is needed.
- **Accept the divergence and document it.** Rejected: `show`/number formatting
  is pervasive and observable; tolerating it would erode the differential
  parity that is the backend's main evidence.
