# Contributing

How changes land in Jurist, how commits are named, and the checks that should
be green before a change is considered done. For *why* the backend is shaped
the way it is, see the [ADRs](./docs/design-decisions); for the runtime
encoding every change has to respect, see
[ADR-0001](./docs/design-decisions/0001-runtime-representation.md).

This repo is small (solo + agent), so it does not run the heavy
branch-protection apparatus its sibling
[`purescript-backend-wasm`](https://github.com/katsujukou/purescript-backend-wasm)
does. What it borrows is that backend's **commit convention** and **judgment
gates** — the parts that keep history legible and the port trustworthy.

## Commit messages

```
[<Category>] <scope>: <summary>
```

- **Category** — one of:
  `Feature` · `Bugfix` · `Refactor` · `Chore` · `Docs` · `Test` · `Perf` · `CI`
- **scope** — what the change touches: an ADR (`ADR-0002`), a code-generator
  subsystem (`Codegen`, `Make`, `Foreigns`, `Runtime`), a Julia-shaped library
  or example (`examples`), the test harness (`test-suite`), or `docs`.
- **summary** — imperative, concise, no trailing period.

Examples:

```
[Feature] Foreigns: shim Random.LCG for same-seed fuzzing
[Bugfix] Foreigns: fix inverted length tiebreak in ordArrayImpl
[Docs] ADR-0002: flag the residual Maybe-representation dependency
[Test] test-suite: add representation canary to the conformance lane
```

Notes:

- **Comment-only changes are `Docs`** (a code comment is documentation),
  scoped by subsystem.
- A design change references its ADR in the scope.
- `Merge` / `Revert` / `fixup!` subjects are exempt.

(Existing history predates this convention; it applies going forward.)

## Before a change is done

The mechanical gate is the **conformance lane** — these must be green for any
code change to the generator, the runtime, or a core shim:

- **Differential suite** — `cd test-suite && python3 run_tests.py` stays at its
  expected count (no new unexpected divergence, no module error). See
  [ADR-0004](./docs/design-decisions/0004-differential-conformance.md).
- **Representation canary** — `examples/repr-canary` still passes (build,
  `purejl`, `julia output-jl/main.jl` prints `all representation contracts
  hold`). A change that alters the runtime encoding must update the
  co-maintained core shims *and* this canary, consciously. See
  [ADR-0002](./docs/design-decisions/0002-ffi-shim-doctrine.md).

On top of the mechanical gate, the author owns these judgment calls:

- **Docs** — a behaviour / representation / feature change is reflected in the
  `README.md`, the relevant ADR(s), and `docs/`. **The implementation is the
  source of truth**, not the prose.
- **Tests** — added or updated for the change. A bug fix carries a regression
  guard in the routinely-run differential suite, not only an ad-hoc check.
- **ADR** — a design change has an ADR (added or updated, `Status` set). ADRs
  are point-in-time records: correct them in place with a struck-through
  (`~~…~~`) original plus a dated addendum, never by rewriting history (see the
  [ADR README](./docs/design-decisions/README.md)).
- **No new divergence smuggled in** — a divergence from the JS reference is
  either fixed or added to `KNOWN_DIVERGENCES` *with its reason prefix* and the
  JS value shown, never left to fail silently.

## Build & run (reference)

```bash
stack build                         # build the purejl code generator
# in a spago project with workspace.backend.cmd: "true":
spago build                         # emits CoreFn
stack exec purejl -- output output-jl
julia output-jl/main.jl
```

The differential suite drives `purs --codegen corefn,js` directly (spago will
not forward `--codegen`); see `test-suite/run_tests.py`.

## Documentation language

Permanent, version-controlled documents (ADRs, `docs/`, this file, READMEs,
code comments) are written in **English**.
