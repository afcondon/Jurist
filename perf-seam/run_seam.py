#!/usr/bin/env python3
"""Run both arms of the seam-tax lane and report what the crossing costs.

    python3 run_seam.py                 # build, run both arms, compare
    python3 run_seam.py --skip-build
    python3 run_seam.py --json

Both arms run the SAME loop over the SAME 400 orbits through the SAME solver.
The only difference is who owns the loop: PureScript compiled to Julia by
purejl, or a plain Julia program. So the delta is the seam and nothing else.

## The four numbers, and which one is the answer

    tax           poly_steady / native_steady
                  the headline, and the least useful on its own — it moves
                  with work-per-call, so quoting one value of it is quoting
                  the operating point you happened to pick.

    distortion    poly_inlib / native_inlib
                  time INSIDE OrdinaryDiffEq, called from PureScript against
                  called from Julia. ~1.0 expected: the library cannot tell
                  who called it. Above ~1.1 means the seam deformed HOW we
                  call it, which is the failure no profiler shows you,
                  because it makes foreign *share* rise and reads as "clean
                  architecture, the library dominates".

    crossing      (poly_steady - poly_inlib)/calls
                    - (native_steady - native_inlib)/calls
                  microseconds of EXTRA overhead per call attributable to
                  PureScript.

This lane was built expecting `crossing` to be CONSTANT across the work axis,
on the reasoning that a crossing cannot know how long the callee will run.
**Measured on Jurist 2026-08-02, that is false**: it grew 5.1 -> 39.8 us as the
call it rides on grew 168 us -> 10 ms. A two-component least-squares fit is
reported instead, because the shape is the finding:

    crossing ~= c0 + c1 * (library work per call)

The proportional term is not a crossing cost at all — a boundary cannot charge
by the callee's duration. It is almost certainly allocation: the polyglot arm
allocates more per call (curried closures, Effect thunks), and collector cost
tracks the heap, which grows with how much the library itself allocated. So
report both terms and do not quote a single microsecond figure as if the
crossing were a fixed toll.

The number that actually answers "is this practical" is therefore the TAX
CURVE, not any one scalar: what fraction over native you pay at the operating
point you are actually at.

## What is checked before anything is reported

Checksums, per row, across both arms. A benchmark that computes a different
answer quickly is the classic way for a perf lane to stay green while what it
measures rots, so a mismatch is fatal rather than a warning.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "1"

POLY = ["julia", "--project=julia-env", "-e",
        'include("output-jl/loader.jl"); Seam_Main.main()']
NATIVE = ["julia", "--project=julia-env", "native/seam_native.jl"]


def build():
    subprocess.run(["spago", "build", "--censor-stats"], cwd=HERE, check=True)
    subprocess.run(
        ["stack", "exec", "--stack-yaml", "../stack.yaml", "purejl", "--",
         "output", "output-jl"],
        cwd=HERE, check=True, stdout=subprocess.DEVNULL)


def run(cmd, label):
    print(f"  running {label} ...", file=sys.stderr, flush=True)
    p = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{label} failed:\n{p.stdout}\n{p.stderr}")
    return parse(p.stdout, label)


def parse(out, label):
    rows, seen_schema = {}, False
    for line in out.splitlines():
        f = line.split()
        if f[:1] == ["SEAM-SCHEMA"]:
            seen_schema = True
            if f[1] != SCHEMA:
                sys.exit(f"{label}: schema {f[1]}, expected {SCHEMA}")
        elif f[:1] == ["SEAM"]:
            # SEAM <axis> <param> <calls> <first> <steady> <inlib> <checksum>
            axis, param, calls, first, steady, inlib, checksum = f[1:8]
            # Julia prints 2.0 where PureScript prints 2.0 for Numbers but the
            # payload axis is Int on one side and may print 16 vs 16.0.
            key = (axis, normalise(param))
            rows[key] = dict(calls=int(calls), first=float(first),
                             steady=float(steady), inlib=float(inlib),
                             checksum=float(checksum))
    if not seen_schema:
        sys.exit(f"{label}: no SEAM-SCHEMA line; did the arm run at all?")
    return rows


def normalise(param):
    """`16` and `16.0` are the same operating point; make them the same key."""
    return f"{float(param):g}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not args.skip_build:
        build()

    native = run(NATIVE, "native (plain Julia)")
    poly = run(POLY, "polyglot (PureScript -> Julia)")

    keys = [k for k in native if k in poly]
    missing = set(native) ^ set(poly)
    if missing:
        sys.exit(f"arms disagree on which rows exist: {sorted(missing)}")

    # Checksums first, always. Timings on rows that computed different answers
    # are not slow-or-fast, they are meaningless.
    #
    # RELATIVE, not absolute. The work-axis checksums are order 400 and the
    # payload-axis ones order 1.4e4, so a fixed absolute bound is a different
    # strictness per row — and the tight one fires on last-bit noise while the
    # loose one would wave through a real divergence. 1e-12 relative is still
    # far tighter than any genuine difference in what is computed: when the
    # two arms really do the same arithmetic in the same order they agree
    # exactly, and every mismatch this gate has caught so far was a real
    # association bug in the native arm, not noise.
    def rel(a, b):
        scale = max(abs(a), abs(b), 1.0)
        return abs(a - b) / scale

    bad = [k for k in keys
           if rel(native[k]["checksum"], poly[k]["checksum"]) > 1e-12]
    if bad:
        for k in bad:
            n, p_ = native[k]["checksum"], poly[k]["checksum"]
            print(f"CHECKSUM MISMATCH {k}: native {n!r} vs poly {p_!r} "
                  f"(relative {rel(n, p_):.3e})", file=sys.stderr)
        sys.exit("checksums differ; the two arms are not running the same "
                 "computation, so no timing here means anything")

    results = []
    for k in sorted(keys, key=lambda k: (k[0], float(k[1]))):
        n, p = native[k], poly[k]
        calls = n["calls"]
        work_us = n["inlib"] / calls
        n_over = (n["steady"] - n["inlib"]) / calls
        p_over = (p["steady"] - p["inlib"]) / calls
        crossing = p_over - n_over
        results.append(dict(
            axis=k[0], param=k[1], calls=calls,
            workPerCallUs=work_us,
            polySteadyUs=p["steady"], nativeSteadyUs=n["steady"],
            polyFirstUs=p["first"], nativeFirstUs=n["first"],
            tax=p["steady"] / n["steady"] if n["steady"] else None,
            distortion=p["inlib"] / n["inlib"] if n["inlib"] else None,
            nativeOverheadPerCallUs=n_over,
            polyOverheadPerCallUs=p_over,
            crossingUs=crossing,
            breakeven5pctUs=crossing / 0.05 if crossing > 0 else 0.0,
            breakeven1pctUs=crossing / 0.01 if crossing > 0 else 0.0,
        ))

    if args.json:
        print(json.dumps(results, indent=2))
        return

    for axis, title, unit in (
        ("work", "WORK PER CALL — how much library work each crossing buys",
         "Jupiter periods"),
        ("payload", "PAYLOAD PER CALL — Numbers returned per crossing "
         "(work held at 15 periods)", "samples"),
    ):
        rs = [r for r in results if r["axis"] == axis]
        if not rs:
            continue
        print()
        print("=" * 92)
        print(f"  {title}")
        print("=" * 92)
        print(f"  {unit:>14}  {'lib work/call':>13}  {'poly':>9}  {'native':>9}"
              f"  {'tax':>6}  {'distort':>7}  {'crossing':>9}")
        print(f"  {'':>14}  {'us':>13}  {'ms':>9}  {'ms':>9}"
              f"  {'':>6}  {'':>7}  {'us/call':>9}")
        print("  " + "-" * 88)
        for r in rs:
            print(f"  {r['param']:>14}  {r['workPerCallUs']:>13.1f}"
                  f"  {r['polySteadyUs']/1000:>9.1f}  {r['nativeSteadyUs']/1000:>9.1f}"
                  f"  {r['tax']:>6.2f}  {r['distortion']:>7.3f}"
                  f"  {r['crossingUs']:>9.2f}")

    work = [r for r in results if r["axis"] == "work"]
    if work:
        print()
        print("=" * 92)
        print("  THE ANSWER")
        print("=" * 92)

        ws = [r["workPerCallUs"] for r in work]
        cs = [r["crossingUs"] for r in work]
        n = len(ws)
        sw, sc = sum(ws), sum(cs)
        sww = sum(x * x for x in ws)
        swc = sum(x * y for x, y in zip(ws, cs))
        den = n * sww - sw * sw
        c1 = (n * swc - sw * sc) / den if den else 0.0
        c0 = (sc - c1 * sw) / n

        print("  The crossing is NOT a fixed per-call toll. Least squares over")
        print("  the work axis:")
        print()
        print(f"      crossing  ~=  {c0:.1f} us  +  {c1*100:.2f} % of the library call")
        print()
        print("  The fixed term is the boundary. The proportional term cannot be")
        print("  — a crossing does not know the callee's duration — and is most")
        print("  likely collector cost tracking a heap the library itself grew.")
        print()
        print("  Tax at each operating point, which is what you actually pay:")
        for r in work:
            print(f"      {r['workPerCallUs']:8.0f} us of library work per call"
                  f"  ->  {r['tax']:.2f}x")
        print()
        best, worst = min(r["tax"] for r in work), max(r["tax"] for r in work)
        print(f"  Across a 60x range of work per call the tax stayed within"
              f" {best:.2f}x-{worst:.2f}x.")
        print()
        d = max(r["distortion"] for r in results)
        verdict = "clean" if d < 1.1 else "DEFORMED — the seam changed how the library is called"
        print(f"  worst structural distortion across all rows  {d:.3f}  ({verdict})")


if __name__ == "__main__":
    main()
