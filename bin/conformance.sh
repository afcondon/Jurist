#!/usr/bin/env bash
# Conformance lane (ADR-0002, ADR-0004): the mechanical gate for any change to
# the code generator, the runtime, or a core shim. Runs the representation
# canary and the cross-backend differential suite; exits non-zero if either
# drifts. CI calls this; a contributor can run it locally before pushing.
#
# Jurist has TWO implementations (ADR-0009), and the lanes below answer
# different questions:
#
#   1. The DIFFERENTIAL suite — the same FFI-free source on JS and Julia,
#      diffed byte-for-byte, through the ORACLE (`purejl`). Answers "does this
#      mean the same thing on both runtimes?", and is what any correctness
#      claim rests on. The representation canary guards the ADR-0001 table it
#      depends on.
#   2. The OPTIMIZER lane — backend-jl/ consuming
#      purescript-backend-optimizer's IR. Same corpus, different path through
#      the compiler.
#   3. The NO-FORK check — backend-jl must not carry its own copy of the
#      runtime or of any foreign shim. Gnomon kept two Go runtimes, they
#      diverged by two symbols, and only a red CI found it; the cheap gate is
#      to assert the second copy does not exist.
#
# Prereqs on PATH: stack, purs, spago, julia, node, python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> building purejl (stack)"
stack build

echo "==> representation canary (examples/repr-canary)"
(
  cd examples/repr-canary
  spago build
  stack exec --stack-yaml "$ROOT/stack.yaml" purejl -- output output-jl
  out="$(julia output-jl/main.jl)"
  echo "$out"
  grep -q "all representation contracts hold" <<<"$out" \
    || { echo "::error::representation canary failed"; exit 1; }
)

echo "==> differential suite (test-suite)"
(
  cd test-suite
  python3 run_tests.py
)

echo "==> optimizer lane: backend-jl over the shared corpus"
if [[ -d ../purescript-backend-optimizer ]]; then
  ( cd backend-jl && ./run_conformance.sh --skip-purejl )
else
  echo "    NOT RUN — ../purescript-backend-optimizer is not checked out beside this repo."
  echo "    The optimizer lane needs it as a local sibling (see backend-jl/README.md)."
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::warning title=Optimizer lane NOT RUN::backend-jl was not tested: ../purescript-backend-optimizer is not checked out. Nothing here vouches for the optimizer lane."
  fi
fi

echo "==> no-fork check: backend-jl owns no runtime and no foreign shims"
strays="$(find backend-jl -name 'purejl_runtime.jl' -o -name '*_foreign.jl' 2>/dev/null || true)"
if [[ -n "$strays" ]]; then
  echo "$strays"
  echo "::error::backend-jl must consume the oracle lane's runtime and shims, not carry copies (ADR-0009)"
  exit 1
fi
echo "    none, as required"

echo "==> performance canary (perf)"
# Gates on CHECKSUMS — the shapes must compute the same answers on both
# backends, and a benchmark that is quietly wrong is how a perf suite stays
# green while what it measures rots.
#
# Timing drift gates too (--gate-drift), wherever this machine has its own
# baseline (perf/baselines/<machine>.json). Where it has none, which includes
# every CI runner, run_perf.py says the drift gate was NOT RUN, in the log and
# as an annotation; checksums gate everywhere. The canary also runs the
# backend-jl lane when the optimizer is checked out, and says NOT RUN when
# it is not.
#
# The drift gate did not gate when the lane was built. What changed is not
# the per-shape tolerance, which is still 2.0x, but the POPULATION it applies
# to. Six back-to-back runs of all three backends on an
# idle machine (2026-08-01) put the worst run-to-run spread over ALL measured
# rows at 5.74x — a 2.0x gate over that would have fired on noise nearly every
# run. Restricted to rows the runner marks as gated — largest n of each shape,
# and only above an absolute floor where the timing carries information — the
# worst spread was 1.69x and the median 1.10x. See CALIBRATION,
# GATE_MIN_STEADY_US and TOLERANCE in run_perf.py.
(
  cd perf
  python3 run_perf.py --gate-drift
)

# Report, not a gate: regenerating here is what stops the index going stale,
# since it is read off the backends' own source. Requires the sibling repos and
# a resolved package set; skipped rather than failed when either is absent.
echo "==> portability index (report)"
if python3 bin/portability-index.py -o /dev/null 2>/dev/null; then
  python3 bin/portability-index.py -o "$ROOT/../../docs/kb/reference/portability-index.md" \
    || echo "note: index generated but not written (docs repo not found)"
else
  echo "note: skipped — sibling backends or resolved package set not available"
fi

echo "==> conformance lane GREEN"
