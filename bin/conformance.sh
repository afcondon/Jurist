#!/usr/bin/env bash
# Conformance lane (ADR-0002, ADR-0004): the mechanical gate for any change to
# the code generator, the runtime, or a core shim. Runs the representation
# canary and the cross-backend differential suite; exits non-zero if either
# drifts. CI calls this; a contributor can run it locally before pushing.
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

echo "==> conformance lane GREEN"
