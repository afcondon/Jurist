#!/bin/zsh
# backend-jl conformance: run the SAME Test.* corpus through the optimizer lane
# and diff it against the JavaScript reference, module by module.
#
# The runtime (`purejl_runtime.jl`) and every foreign shim (`*_foreign.jl`) come
# from `purejl` -- the oracle lane -- and are copied in unmodified. Neither is
# generated here and neither is checked in under backend-jl, so the two lanes
# cannot drift the way Gnomon's two Go runtimes did (they diverged by two symbols
# and it took a red CI to notice).
#
# A module is "green" if its output is byte-identical to node's, or differs ONLY
# on the seeded divergence ledger (INT64: Jurist's Int is Int64 and does not wrap
# at 32 bits, ADR-0001; ASTRAL: Julia strings are codepoint-indexed, not UTF-16
# code units; STACK: no JS stack traces; NEGZERO: purs inlines negate to unary
# minus, the backends lower it faithfully as `0.0 - 0.0`, #48).
#
# Usage: ./run_conformance.sh [--skip-purejl]
set -e
HERE=${0:A:h}
SUITE="$HERE/../test-suite"
BASE="$SUITE/output-jl"          # purejl's output: the shared runtime + foreigns
# Scratch paths are PER RUN, not fixed. All three optimizer lanes previously
# wrote /tmp/js_out.txt, so running two of them at once silently crossed their
# reference output and produced diffs full of another module's tests — three
# invented failures that looked exactly like real regressions. A gate whose
# result depends on what else is running is not a gate.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
OUT=/tmp/bjl-conf

# Corpus modules are DISCOVERED, never listed by hand -- a hand-maintained list
# is how Test.Maps sat unexecuted in the Gnomon repo for weeks. Benchmarks are
# the only exclusion: they measure rather than assert and print no TEST lines.
mods=(${(f)"$(cd "$SUITE/src/Test" && ls *.purs | sed 's/\.purs$//' | grep -v '^Bench')"})

if [[ "$1" != "--skip-purejl" ]]; then
  echo "==> building purejl (the oracle lane supplies the runtime + foreigns)"
  (cd "$HERE/.." && stack build 2>&1 | tail -3)
  echo "==> purejl -> $BASE"
  (cd "$SUITE" && stack exec --stack-yaml ../stack.yaml purejl -- output output-jl >/dev/null)
fi

echo "==> building backend-jl"
(cd "$HERE" && spago build >/dev/null 2>&1)

# Per-entry pruning means each program is emitted for its OWN main: emitting
# --main Test.X prunes every binding unreachable from Test.X.main, so we emit
# once per module into a clean directory.
# The seeded divergence ledger, as name markers. See the per-line check
# below for why markers rather than a list of (module, test) pairs.
LEDGER_MARKERS="INT64|ASTRAL|STACK|NEGZERO"
pass=0; ledger=0; bad=0
for m in $mods; do
  mod="Test.$m"
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$HERE" && spago run -- --corefn-dir "$SUITE/output" --output-dir "$OUT" --main "$mod" >/dev/null 2>&1)
  # The shared runtime and every foreign shim, verbatim from the oracle lane.
  cp "$BASE/purejl_runtime.jl" "$OUT/"
  cp "$BASE"/*_foreign.jl "$OUT/" 2>/dev/null || true
  if ! julia "$OUT/main.jl" > "$TMPD/jl_out.txt" 2>"$TMPD/jl_err.txt"; then
    echo "[$mod] RUN-ERR: $(grep -m1 -E 'ERROR|Error' "$TMPD/jl_err.txt" | head -c 160)"; bad=$((bad+1)); continue
  fi
  node --input-type=module -e "import(\"$SUITE/output/$mod/index.js\").then(x => x.main())" > "$TMPD/js_out.txt" 2>/dev/null
  nfiles=$(ls "$OUT"/*.jl | wc -l | tr -d ' ')
  if diff -q "$TMPD/js_out.txt" "$TMPD/jl_out.txt" >/dev/null; then
    echo "[$mod] OK identical ($(wc -l <"$TMPD/jl_out.txt"|tr -d ' ') lines, $nfiles files)"; pass=$((pass+1))
  else
    # Every DIVERGING LINE must carry a ledger marker, not merely one of them.
    # `grep -q` over the whole diff passes a module that has one ledgered
    # divergence AND one real regression — which is precisely how a gate stays
    # green while it is broken. Test.Boundaries was doing exactly that: 13 of
    # its ledgered entries had no marker and rode in on the ASTRAL/INT64 ones.
    #
    # This works because a ledgered divergence names its own cause: the
    # convention is an INT64- / ASTRAL- / STACK- / NEGZERO- prefix on the test
    # name, so both this lane and the oracle lane's explicit pair list read the
    # same signal out of the same string, and there is no second list to drift.
    unledgered="$(diff "$TMPD/js_out.txt" "$TMPD/jl_out.txt" \
                  | grep -E '^[<>]' | grep -viE "$LEDGER_MARKERS" || true)"
    if [ -z "$unledgered" ]; then
      echo "[$mod] OK ledger-only ($LEDGER_MARKERS, $nfiles files)"; ledger=$((ledger+1))
    else
      echo "[$mod] FAIL:"; echo "$unledgered" | head -8; bad=$((bad+1))
    fi
  fi
done
echo "=== $pass identical + $ledger ledger-only = $((pass+ledger))/${#mods[@]} green; $bad bad ==="
[ $bad -eq 0 ]
