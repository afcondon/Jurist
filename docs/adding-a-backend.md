# Adding a backend column to the differential suite

Instructions for an agent session tasked with extending the
cross-backend differential matrix (see `backend-comparison.md` and
Marginalia projects 134/220) to purerl, purepy, or purescript-go.
Written after building the Julia column; the lessons below are the ones
that cost time.

## The contract

"Adding a backend" means, concretely:

1. **Build path**: compile `test-suite/src/Test/*.purs` to runnable
   artifacts on your backend. The suite is deliberately FFI-free beyond
   the core libraries, so the only foreign code you need is the
   backend's own core-library shims.
2. **Runner**: a `run_<backend>(module) -> (stdout, error)` function in
   `test-suite/run_tests.py`, plus the module-name mapping (see table
   below). Runners must be pure subprocess calls — no shared state.
3. **Divergence curation**: every non-identical line either becomes a
   fix (your shim is wrong) or a `KNOWN_DIVERGENCES` entry with a
   prefix naming the cause (`INT64-`, `ASTRAL-`, `BIGNUM-`, `FLOATFMT-`,
   …) AND a sentence in the backend's README. An uncurated divergence
   is a failure. **Counterexamples are first-class content** — the
   site's thesis is that divergences are enumerable, so finding one is
   a result, not an embarrassment.
4. **Results as data**: emit one JSONL record per (program, backend,
   test) — the site renders from this. Don't print prose summaries
   only.
5. **Regression**: the existing columns (Node, Julia) must still pass.

Module-name mappings:

| PS module | JS | Julia | Erlang (purerl) | Python (purepy) |
|---|---|---|---|---|
| `Test.Arrays` | `output/Test.Arrays/index.js` | `Test_Arrays` | `test_arrays@ps` | snake-cased module in `output-py/` |

`main` is an `Effect Unit` — a nullary closure on every backend. You
must *apply* it: `m.main()` (JS), `Test_Arrays.main()` (Julia — the
generated value is the thunk), `('test_arrays@ps':main())()` (Erlang —
note the double application: fetch, then run).

## Ground rules (learned the hard way)

- **Read the real JS foreign modules** (`.spago/p/<pkg>/src/**/*.js`),
  never another backend's shims. The python backend's shim names were
  cargo-culted at least once. The JS file is the spec; the `.purs`
  `foreign import` declarations give you arities (`Fn4` = genuine
  4-arg function if your representation uncurries them).
- **JS arity tolerance does not port.** JS foreigns call `f()` on
  functions that CoreFn types as 1-ary (the Partial dict, `mkFn0`'s
  `Unit -> a`). Your shim must pass the argument explicitly
  (`f(nothing)` in Julia). Grep the JS for zero-arg calls.
- **Some "foreign-looking" names are PS-defined.** `mkFn1`/`runFn1`
  are written in PureScript; shimming them collides with the generated
  module body. Trust the corefn.json `foreign` array, nothing else.
- **The reference is not always "right".** `sumTo 0 1000000` *overflows*
  on the JS backend (int32 wrap). When your backend's answer is better,
  document the divergence with a prefix — don't cripple your runtime to
  match, and don't silently diverge. BEAM bignum and Python int will
  hit this immediately: expect the `INT64-` tests to need a third
  expected value (the suite currently encodes JS-vs-Julia; turn the
  entry into per-backend expectations when you add a third).
- **Number formatting is the biggest hidden surface.** JS
  `Number.prototype.toString` placement rules (decimal within
  1e-6 ≤ |n| < 1e21, exponential outside, `.0` suffix via Show) had to
  be reimplemented for Julia (`_js_number_string` in the runtime).
  Erlang's and Python's default float printing differ from JS in
  exactly these zones. Run `Test.Numbers` early — it will tell you
  whether your backend's `showNumberImpl` needs the same treatment.
- **Sort stability is tested** (`sort-stable`). JS `sortByImpl` is a
  stable merge sort. Check what your backend's shim actually does.
- **`ordArrayImpl`'s length tiebreak is inverted** (longer → -1; the
  PS caller re-inverts via `compare 0 _`). We shipped this bug; the
  suite caught it. Check your backend's prelude shims for the same
  trap — any foreign whose sign convention is consumed inverted.
- **stack snapshot reuse**: if you build a Haskell-based backend
  (purerl, purepy), copy `stack.yaml` AND `stack.yaml.lock` from a
  sibling that already builds — the lock pins the GitHub tarball hash
  that determines the snapshot key. Without it: ~25 min rebuild;
  with it: ~90 s.

## purerl (Erlang/BEAM)

- **Toolchain**: local source checkout at
  `purescript-backends/purerl` (stack project, exe `purerl`); a
  prebuilt npm binary also exists at
  `music/live-coding/purerl-tidal/node_modules/.bin/purs-backend-erl`.
  Erlang/OTP is installed (`/opt/homebrew/bin/erl`, `erlc`).
- **CRITICAL — package sets**: purerl does NOT compile against the
  registry's JS core libraries. It needs the purerl forks, via its own
  package set. See `music/live-coding/purerl-tidal/spago.yaml` for a
  working example:
  `workspace.packageSet.url: https://raw.githubusercontent.com/purerl/package-sets/erl-0.15.3-20220629/packages.json`
  and `backend.cmd: purs-backend-erl` (or `purerl`).
  Consequence: the suite needs a **second workspace**
  (`test-suite-erl/`) with its own `spago.yaml`; share the PS sources
  by relative glob or symlink to `../test-suite/src`. Check whether
  the pinned set's compiler version matches the installed purs
  (0.15.x) before debugging anything else.
- **Build & run**: `spago build` emits `output/<Module>/<module>@ps.erl`
  (purerl is invoked per-module on corefn). Then:
  `erlc -o ebin output/*/*.erl` and
  `erl -pa ebin -noshell -eval "('test_arrays@ps':main())(), init:stop()."`
- **Expected divergences**: Int is bignum (`INT64-` tests give exact
  answers like Julia — note JS is the odd one out, the entry needs
  per-backend expectations); float printing (Erlang's
  `io_lib:format`-based Show may differ in exponent zones — discover
  differentially); possibly string Show escaping. Strings are UTF-8
  binaries; the ASTRAL- tests should agree with Julia, not JS.
- The purerl core libs are mature — expect FEW shim bugs; most
  divergence will be deliberate grain.

## purepy (purescript-python-new)

- **Toolchain**: sibling repo `purescript-backends/purescript-python-new`
  (stack project, exe `purepy`). Its own `test-project/` contains
  `cross_backend_test.py` — **prior art for this exact task**, with a
  curated KNOWN_DIVERGENCES set (emoji/code-unit entries). Port those
  entries; don't rediscover them.
- **Build & run**: spago with `backend.cmd: "true"` for corefn (same
  trick as Jurist), then `purepy output output-py`. Modules are
  snake-cased files; run via
  `python3 -c "import sys; sys.path.insert(0,'output-py'); import test_arrays; test_arrays.main()"`.
  Verify the exact snake-casing purepy produces for `Test.ADTs`
  (historically `test_cross_backend_a_d_ts` — acronyms split oddly).
- **Audit while you're there**: purepy's shims predate the
  read-the-real-JS rule. Validate its foreign names against
  corefn.json `foreign` arrays for every module the suite touches.
  Fixing purepy is in scope and valuable.
- **Expected divergences**: Python int is bignum (same as BEAM);
  float repr differs from JS (e.g. 1e16 zone, `inf` vs `Infinity` if
  unshimmed); `ASTRAL-` tests agree with Julia.

## purescript-go (purescript-native)

- **Not local yet.** Clone `github.com/andyarvanitis/purescript-native`
  (driver: `psgo`) and its companion Go FFI:
  `github.com/purescript-native/go-ffi`. Needs a Go toolchain
  (`brew install go` if `which go` fails).
- psgo consumes corefn and produces **one executable per Main** — ten
  test modules would mean ten builds. Preferred integration: add a
  dispatcher `Main.purs` to the suite that switches on its first CLI
  arg (`main = getArgs >>= case _ of ["Test.Arrays"] -> Arrays.main; …`
  — needs an argv foreign or `node-process`-equivalent per backend, so
  weigh it; compiling N small mains may honestly be simpler).
- Expect the *least* coverage here: go-ffi tracks an older core-library
  era. Budget time for missing shims, and treat each as a finding for
  the comparison table's "library coverage" row.
- **Expected divergences**: Int is int (64-bit on arm64) — Julia-like;
  float formatting via strconv differs from JS; strings UTF-8.

## Harness integration

Refactor `run_tests.py` from hardcoded `run_js`/`run_julia` to a
registry:

```python
BACKENDS = {
    "js":     Backend(build=build_js, run=run_js, ref=True),
    "julia":  Backend(build=build_julia, run=run_julia),
    "erl":    Backend(...),
    ...
}
# --backends erl,julia ; default: all available (probe toolchains, skip
# missing with a SKIPPED record, never a silent drop)
```

Diff every backend against the reference, AND pairwise where both
diverge from JS the same way (bignum backends should agree with each
other — that's a checkable claim). KNOWN_DIVERGENCES becomes
`(module, test) -> {backend_or_class: expected}` — divergence classes
(`bignum`, `utf8`) beat per-backend entries where they apply.

## Definition of done

- All ten `Test.*` modules run on the new backend; counts reported.
- Zero uncurated divergences; every curated one has a prefix, a
  per-backend (or per-class) expectation, and a README sentence.
- JSONL results emitted; existing columns still green.
- `backend-comparison.md` column updated from observed facts (not
  documentation folklore) — cite test names in cell footnotes where
  the table makes a checkable claim.
- Worklog + Marginalia note (project 220) per ecosystem conventions.
