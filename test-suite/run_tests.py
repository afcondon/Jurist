#!/usr/bin/env python3
"""
Cross-backend differential test runner for purescript-julia (Jurist).

Builds the test modules once with `purs --codegen corefn,js` (via spago),
generates Julia with purejl, then runs every Test.* module on BOTH
backends and diffs their TEST lines:

    TEST <name>: <value>

A test passes when the JS backend (the reference semantics) and the
Julia backend print byte-identical values. Divergences listed in
KNOWN_DIVERGENCES are reported but don't fail the run; they document
deliberate representation differences (UTF-16 code units vs codepoints).

Usage:
    cd test-suite
    python3 run_tests.py              # build + run everything
    python3 run_tests.py --skip-build # reuse existing output/ + output-jl/
    python3 run_tests.py Strings      # only modules matching a substring

Exit code: 0 iff no unexpected divergences and no module-level errors.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

TEST_MODULES = [
    "Test.ADTs",
    "Test.Arrays",
    "Test.Dictionaries",
    "Test.Effects",
    "Test.Numbers",
    "Test.PatternMatch",
    "Test.Recursion",
    "Test.STTests",
    "Test.Strings",
    "Test.Uncurried",
]

# Deliberate divergences (module, test-name), documented in the README:
# - ASTRAL-: JS counts UTF-16 code units; the Julia backend counts
#   codepoints. Identical for BMP text.
# - INT64-: JS wraps every Int operation to int32 (`|0`); the Julia
#   backend keeps Int64 exactness. The JS values here are OVERFLOWED.
KNOWN_DIVERGENCES = {
    ("Test.Strings", "ASTRAL-cu-length-emoji"),
    ("Test.Strings", "ASTRAL-cu-take-emoji"),
    ("Test.Recursion", "INT64-sumTo-1e6"),
    ("Test.Recursion", "INT64-fact-20"),
}

TEST_LINE = re.compile(r"^TEST ([^:]+): (.*)$")


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=HERE, **kw)


def build():
    # Ensure dependency sources are materialized under .spago/p. On a fresh
    # checkout `spago sources` only prints globs; `spago build` is what fetches
    # and unpacks the packages those globs point at. (Its JS output is unused —
    # the corefn,js compile below regenerates everything.) Locally this is a
    # no-op once deps are present; on CI it is what makes the globs resolve.
    print("• materializing deps (spago build)...", file=sys.stderr)
    r = sh(["spago", "build"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"spago build failed ({r.returncode})")
    # spago won't forward --codegen, so resolve the source globs through
    # `spago sources` and drive purs directly with both codegen targets.
    print("• resolving sources (spago)...", file=sys.stderr)
    r = sh(["spago", "sources"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"spago sources failed ({r.returncode})")
    globs = r.stdout.split()
    print("• purs compile --codegen corefn,js...", file=sys.stderr)
    r = sh(["purs", "compile", "--codegen", "corefn,js"] + globs)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"purs compile failed ({r.returncode})")
    print("• purejl output -> output-jl...", file=sys.stderr)
    r = sh(["stack", "exec", "--stack-yaml", "../stack.yaml", "purejl", "--",
            "output", "output-jl"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"purejl failed ({r.returncode})")
    for line in r.stdout.splitlines():
        if "Warning" in line:
            print("  " + line, file=sys.stderr)


def run_js(module):
    path = f"./output/{module}/index.js"
    if not (HERE / path).exists():
        return None, f"missing {path}"
    r = sh(["node", "--input-type=module", "-e",
            f'import("{path}").then(m => m.main())'], timeout=120)
    if r.returncode != 0:
        return None, f"node exit {r.returncode}: {r.stderr.strip()[:300]}"
    return r.stdout, None


def run_julia(module):
    jl_mod = module.replace(".", "_")
    r = sh(["julia", "-e",
            f'include("output-jl/loader.jl"); {jl_mod}.main()'], timeout=300)
    if r.returncode != 0:
        return None, f"julia exit {r.returncode}: {r.stderr.strip()[:300]}"
    return r.stdout, None


def parse_tests(stdout):
    tests = {}
    order = []
    for line in stdout.splitlines():
        m = TEST_LINE.match(line)
        if m:
            tests[m.group(1)] = m.group(2)
            order.append(m.group(1))
    return tests, order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    if not args.skip_build:
        build()

    modules = [m for m in TEST_MODULES if args.filter.lower() in m.lower()]
    total = passed = known = 0
    failures = []
    errors = []

    for mod in modules:
        js_out, js_err = run_js(mod)
        jl_out, jl_err = run_julia(mod)
        if js_err or jl_err:
            errors.append((mod, js_err or jl_err))
            print(f"{mod}: ERROR {js_err or jl_err}", file=sys.stderr)
            continue
        js_tests, js_order = parse_tests(js_out)
        jl_tests, _ = parse_tests(jl_out)
        mod_pass = mod_fail = 0
        for name in js_order:
            total += 1
            jsv = js_tests.get(name)
            jlv = jl_tests.get(name)
            if jsv == jlv:
                passed += 1
                mod_pass += 1
            elif (mod, name) in KNOWN_DIVERGENCES:
                known += 1
                print(f"  KNOWN  {mod}/{name}: js={jsv!r} julia={jlv!r}",
                      file=sys.stderr)
            else:
                mod_fail += 1
                failures.append((mod, name, jsv, jlv))
                print(f"  FAIL   {mod}/{name}: js={jsv!r} julia={jlv!r}",
                      file=sys.stderr)
        missing = set(js_tests) - set(jl_tests)
        extra = set(jl_tests) - set(js_tests)
        if missing or extra:
            errors.append((mod, f"line mismatch missing={missing} extra={extra}"))
        print(f"{mod}: {mod_pass} pass, {mod_fail} fail", file=sys.stderr)

    print(f"\n{passed}/{total} identical, {known} known divergences, "
          f"{len(failures)} failures, {len(errors)} module errors",
          file=sys.stderr)
    sys.exit(0 if not failures and not errors else 1)


if __name__ == "__main__":
    main()
