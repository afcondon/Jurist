# Design Decisions

This directory records the significant architectural decisions for Jurist —
the PureScript → Julia backend — as lightweight
[ADRs](https://adr.github.io/) (Architecture Decision Records).

Each record captures **one** decision: the context that forced it, the
decision itself, its consequences, and the alternatives that were rejected
and why. A record's original text is never deleted-and-replaced — history is
preserved in place (see [Maintaining records](#maintaining-records)). A
genuinely *reversed* decision is retired by a new record that supersedes it,
not by rewriting the old one.

The format and maintenance discipline here are deliberately the same as the
sibling [`purescript-backend-wasm`](https://github.com/katsujukou/purescript-backend-wasm)
backend's, so the wider PureScript-backends family stays legible to a reader
(or a contributing agent) moving between them.

## Format

```plain
# <NNNN>. <Title>

- Status: Proposed | Accepted | Superseded by <NNNN>
- Date: YYYY-MM-DD

## Context
## Decision
## Consequences
## Alternatives considered
```

## Maintaining records

When a record drifts from the implementation, **do not delete and replace the
original text.** Keep the original readable as history and mark the change in
place:

- **Correction / progress addendum** — strike the obsolete text with `~~…~~`
  and append a dated note, e.g. `> **Progress (YYYY-MM-DD):** …`.
- **Status promotion** — keep the old status struck through and add the new
  one with a dated rationale, e.g.
  `- Status: ~~Proposed~~ **Accepted** _(YYYY-MM-DD: implemented in …)_`.
- **Reversal** — a genuinely overturned decision is retired by a new record
  that supersedes it (`Status: Superseded by <NNNN>`), not by rewriting it.
- **The index below is the exception** — it is edited by direct overwrite, as
  a derived table that must always show each record's current status.

## Index

| # | Title | Status |
| - | - | - |
| 0001 | [Runtime representation of PureScript values in Julia](0001-runtime-representation.md) | Accepted |
| 0002 | [FFI shim doctrine: real-JS foreigns and representation independence](0002-ffi-shim-doctrine.md) | Accepted |
| 0003 | [Tail-call optimization via self-tail-call dispatch loops](0003-tco-trampoline.md) | Accepted |
| 0004 | [The differential suite as conformance mechanism](0004-differential-conformance.md) | Accepted |
| 0005 | [Reproducing JS `Number.prototype.toString` formatting](0005-js-number-formatting.md) | Accepted |
| 0006 | [Module-per-module layout, topological loader, lazy-thunk runtime](0006-module-layout-loader.md) | Accepted |
| 0007 | [Julia-shaped libraries: descriptions across, handles back](0007-julia-shaped-libraries.md) | Proposed |
| 0008 | [Same-seed differential fuzzing](0008-differential-fuzzing.md) | Proposed |

## Scope

Jurist is a from-scratch CoreFn → Julia code generator (Haskell; the `purejl`
binary), sibling of `purescript-python-new`. It consumes the CoreFn JSON that
`purs` emits when a spago workspace sets `workspace.backend.cmd`, and writes
one Julia `module` per PureScript module plus a topologically-ordered loader.
Working today: Hello-World through the core libraries (prelude, effect,
console, refs, st, arrays incl. `Data.Array.ST`, strings, foldable-traversable,
integers, numbers, unfoldable, enums); self-tail-call TCO; a cross-backend
differential suite at 422/426 byte-identical with the reference JS backend.

The authoritative, up-to-date status lives in the repo
[`README.md`](../../README.md); these records capture *why* the backend is
shaped the way it is. Frontiers not yet decided or still proposed (a real
`Data.String.Regex`, mutual-recursion trampolining, QuickCheck same-seed
differential fuzzing, the Julia-shaped-library tiers in
[`../julia-shaped-libraries.md`](../julia-shaped-libraries.md)) will get
records as they are settled.
