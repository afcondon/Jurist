#!/usr/bin/env python3
"""The demo lane: rebuild every example and hold it to what it committed.

Until November 2026 nothing gated the examples. Every figure on the demo
site came from a run in June to August 2026, the runtime representation
changed underneath them in October, and nothing showed they still built. A
review found claims on the site that the code did not support. This lane is
the gate that was missing.

For each example it does what the example's README tells a reader to do:

    spago build
    purejl output output-jl
    julia --project=julia-env output-jl/main.jl

and then checks what came out, in one of two ways:

  * DATA.  The example writes a data file (`patterns.js`, `petri.js`, ..)
    and a copy is committed in its `*-viz/` directory for the page to draw.
    The fresh file must match the committed one: exactly, or number by
    number within a stated tolerance where a solver produced the numbers.
    Text between the numbers must always match exactly.
  * TRANSCRIPT.  The example only prints. Its standard output must equal the
    committed `expected-output.txt` beside it.

It also checks that every file under `site/data/` is the copy the site says
it is.

A lane that cannot run prints NOT RUN and says why; it never passes
silently. The last line says how many examples were checked, how many
failed and how many did not run, and the exit code is non-zero if any
failed. With --strict, a NOT RUN fails too.

Usage:
    bin/demos.py                 # every example
    bin/demos.py petri-catlab    # the named ones
    bin/demos.py --record NAME   # rewrite NAME's committed copy from this
                                 # run. A deliberate act: say why in the
                                 # commit message.
    bin/demos.py --list

Prereqs on PATH: stack, purs, spago, julia, node, python3. The Julia
packages come from each example's `julia-env/` (Project.toml and the
committed Manifest.toml), installed on first use by `Pkg.instantiate()`.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPLES = ROOT / "examples"
SITE_DATA = ROOT / "site" / "data"

NUMBER = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


@dataclass
class Output:
    """A file the example writes, and the committed copy it must match."""

    produced: str            # relative to the example's run directory
    committed: str           # relative to examples/
    rtol: float = 0.0        # 0 and 0: the files must be byte-identical
    atol: float = 0.0


@dataclass
class Demo:
    name: str
    directory: str                       # relative to examples/, where it runs
    julia_env: str | None = "julia-env"  # None: plain julia, no packages
    outputs: list[Output] = field(default_factory=list)
    transcript: bool = False             # compare stdout to expected-output.txt
    threads: str | None = None
    # A dependency spago fetched from git, whose checkout the example reads
    # from: a glob under the example's `.spago/g/`. `{checkout}` in `args`
    # and in `directories` stands for the directory it matches.
    checkout: str | None = None
    args: list[str] = field(default_factory=list)   # passed to main.jl
    # (produced directory, committed directory): the same file names, each
    # byte-identical. The produced one is relative to the run directory.
    directories: list[tuple[str, str]] = field(default_factory=list)


# A tolerance is a claim about the example, so each one says where it comes
# from. Exact (no tolerance) is the default and is right wherever the result
# is combinatorial: a homomorphism search either finds the same matches or
# it does not.
DEMOS = [
    Demo("catlab-patterns", "catlab-patterns",
         outputs=[Output("patterns.js", "catlab-patterns/pattern-viz/patterns.js")]),
    Demo("catlab-schema", "catlab-schema",
         outputs=[Output("schema.js", "catlab-schema/schema-viz/schema.js")]),
    Demo("catlab-migration", "catlab-migration",
         outputs=[Output("migration.js", "catlab-migration/migration-viz/migration.js")]),
    # An adaptive ODE solve (Tsit5 at default tolerances), sampled at 201
    # points. The committed run and a fresh one differ only if the solver or
    # its dependencies moved; 1e-6 relative is far inside the solver's own
    # 1e-3 default and far outside floating-point noise.
    Demo("petri-catlab", "petri-catlab",
         outputs=[Output("petri.js", "petri-catlab/petri-viz/petri.js", rtol=1e-6, atol=1e-9)]),
    Demo("dimensioned", "dimensioned",
         outputs=[Output("dimensioned.js", "dimensioned/dimensions-viz/dimensioned.js")]),
    # The pendulum is chaotic, so a difference in the last bit of one step
    # grows over the 20 s run. Measured 2026-11-19 on one machine (M4, Julia
    # 1.12.6): two runs on the same Manifest are byte-identical for every
    # output here, so the tolerances below are slack for another CPU, not
    # something this machine needs. If another machine exceeds them on the
    # pendulum, that is chaos and not a fault; say so here and widen it.
    Demo("numexpr-edsl", "numexpr-edsl/julia",
         outputs=[
             Output("derivatives.js", "numexpr-edsl/diff-viz/derivatives.js"),
             Output("roots.js", "numexpr-edsl/roots-viz/roots.js", rtol=1e-9, atol=1e-12),
             Output("optimize.js", "numexpr-edsl/opt-viz/optimize.js", rtol=1e-9, atol=1e-12),
             Output("units.js", "dimensioned/dimensions-viz/units.js"),
             Output("double-pendulum.json", "numexpr-edsl/viz/public/double-pendulum.json",
                    rtol=1e-6, atol=1e-9),
         ]),
    Demo("st-number-vector", "st-number-vector", julia_env=None, transcript=True),
    Demo("lorenz-leaf", "lorenz-leaf", julia_env=None, transcript=True),
]

# site/data/<file> must be the committed copy named here. `pendulum.js` is
# the pendulum JSON wrapped in a `window.PENDULUM = ...;` assignment.
SITE_COPIES = {
    "patterns.js": "catlab-patterns/pattern-viz/patterns.js",
    "schema.js": "catlab-schema/schema-viz/schema.js",
    "migration.js": "catlab-migration/migration-viz/migration.js",
    "petri.js": "petri-catlab/petri-viz/petri.js",
    "dimensioned.js": "dimensioned/dimensions-viz/dimensioned.js",
    "units.js": "dimensioned/dimensions-viz/units.js",
    "derivatives.js": "numexpr-edsl/diff-viz/derivatives.js",
    "roots.js": "numexpr-edsl/roots-viz/roots.js",
    "optimize.js": "numexpr-edsl/opt-viz/optimize.js",
}


class NotRun(Exception):
    pass


class Failed(Exception):
    pass


def annotate(kind: str, message: str) -> None:
    """A GitHub Actions annotation; plain text anywhere else."""
    print(f"::{kind}::{message}")


def run(cmd: list[str], cwd: Path, log: Path, timeout: int = 3600) -> str:
    """Run a step, append everything it prints to the log, return stdout."""
    with log.open("a") as out:
        out.write(f"\n$ {' '.join(cmd)}   (in {cwd})\n")
    try:
        done = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Failed(f"`{' '.join(cmd)}` did not finish in {timeout} s")
    with log.open("a") as out:
        out.write(done.stdout)
        out.write(done.stderr)
    if done.returncode != 0:
        tail = "\n".join((done.stdout + done.stderr).strip().splitlines()[-12:])
        raise Failed(f"`{' '.join(cmd)}` exited {done.returncode}\n{tail}")
    return done.stdout


def compare(fresh: str, committed: str, rtol: float, atol: float) -> tuple[bool, str]:
    """Hold a fresh file to its committed copy.

    Returns (ok, what was found). With no tolerance the two must be
    identical. With one, the text between the numbers must be identical and
    each number must agree within `atol + rtol * |committed|`.
    """
    if fresh == committed:
        return True, "identical"
    if rtol == 0.0 and atol == 0.0:
        return False, "differs, and this output is held to exact equality"
    if NUMBER.split(fresh) != NUMBER.split(committed):
        return False, "the text between the numbers differs"
    worst_rel = 0.0
    worst = None
    for a, b in zip(NUMBER.findall(fresh), NUMBER.findall(committed)):
        x, y = float(a), float(b)
        gap = abs(x - y)
        if gap > atol + rtol * abs(y):
            worst = worst or (a, b)
        if y != 0.0:
            worst_rel = max(worst_rel, gap / abs(y))
    if worst:
        return False, (f"numbers differ beyond rtol {rtol:g} / atol {atol:g}: "
                       f"first {worst[0]} against committed {worst[1]}; "
                       f"largest relative difference {worst_rel:.3g}")
    return True, f"within tolerance (largest relative difference {worst_rel:.3g})"


def check_demo(demo: Demo, record: bool, logs: Path) -> list[str]:
    """Build, run and check one example. Returns the lines to report."""
    cwd = EXAMPLES / demo.directory
    log = logs / f"{demo.name}.log"
    log.write_text("")
    for tool in ("stack", "spago", "julia"):
        if shutil.which(tool) is None:
            raise NotRun(f"`{tool}` is not on PATH")

    julia = ["julia"]
    if demo.threads:
        julia += ["-t", demo.threads]
    if demo.julia_env:
        env = cwd / demo.julia_env
        if not (env / "Manifest.toml").exists():
            raise NotRun(f"{env.relative_to(ROOT)}/Manifest.toml is missing, so the "
                         "packages are not pinned; resolve it once with "
                         "`julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'` "
                         "and commit it")
        julia += [f"--project={demo.julia_env}"]
        run(julia + ["-e", "using Pkg; Pkg.instantiate()"], cwd, log)

    for stale in [o.produced for o in demo.outputs]:
        (cwd / stale).unlink(missing_ok=True)
    for produced, _ in demo.directories:
        shutil.rmtree(cwd / produced, ignore_errors=True)
        (cwd / produced).mkdir(parents=True)
    run(["spago", "build"], cwd, log)
    run(["stack", "exec", "--stack-yaml", str(ROOT / "stack.yaml"), "purejl", "--",
         "output", "output-jl"], cwd, log)

    checkout = ""
    if demo.checkout:
        found = sorted((cwd / ".spago" / "g").glob(demo.checkout))
        if len(found) != 1:
            raise Failed(f"expected one git checkout matching .spago/g/{demo.checkout} "
                         f"after `spago build`, found {len(found)}")
        checkout = str(found[0])
    args = [a.replace("{checkout}", checkout) for a in demo.args]
    stdout = run(julia + ["output-jl/main.jl"] + args, cwd, log)

    lines = []
    problems = []
    for o in demo.outputs:
        produced = cwd / o.produced
        committed = EXAMPLES / o.committed
        if not produced.exists():
            problems.append(f"{o.produced}: the run did not write it")
            continue
        if record:
            committed.write_text(produced.read_text())
            lines.append(f"{o.produced}: RECORDED to {committed.relative_to(ROOT)}")
            continue
        if not committed.exists():
            problems.append(f"{o.produced}: no committed copy at {committed.relative_to(ROOT)}")
            continue
        ok, found = compare(produced.read_text(), committed.read_text(), o.rtol, o.atol)
        (lines if ok else problems).append(f"{o.produced}: {found}")

    for produced, committed in demo.directories:
        fresh_dir = cwd / produced
        committed_dir = Path(committed.replace("{checkout}", checkout))
        if record:
            problems.append(f"{produced}/: its committed copy belongs to another "
                            "repository and is not recorded from here")
            continue
        want = sorted(p.name for p in committed_dir.iterdir() if p.is_file())
        have = sorted(p.name for p in fresh_dir.iterdir() if p.is_file())
        if not want:
            problems.append(f"{produced}/: nothing committed to compare with in {committed_dir}")
        if want != have:
            problems.append(f"{produced}/: the run wrote {have}, the committed set is {want}")
        same = [n for n in want if n in have
                and (fresh_dir / n).read_bytes() == (committed_dir / n).read_bytes()]
        differ = [n for n in want if n in have and n not in same]
        if differ:
            problems.append(f"{produced}/: differ from the committed files: {', '.join(differ)}")
        if same:
            lines.append(f"{produced}/: {len(same)} of {len(want)} files identical")

    if demo.transcript:
        expected = cwd / "expected-output.txt"
        if record:
            expected.write_text(stdout)
            lines.append(f"stdout: RECORDED to {expected.relative_to(ROOT)}")
        elif not expected.exists():
            raise NotRun(f"{expected.relative_to(ROOT)} is not committed; "
                         f"record it with `bin/demos.py --record {demo.name}`")
        elif stdout == expected.read_text():
            lines.append(f"stdout: identical ({len(stdout.splitlines())} lines)")
        else:
            problems.append("stdout differs from expected-output.txt")

    if problems:
        raise Failed("\n".join(problems + lines))
    return lines


def check_site_copies() -> list[str]:
    """Every file the site draws from must be the copy it claims to be."""
    problems = []
    for name, source in SITE_COPIES.items():
        site, viz = SITE_DATA / name, EXAMPLES / source
        if not site.exists() or not viz.exists():
            problems.append(f"site/data/{name}: missing, or its source {source} is")
        elif site.read_bytes() != viz.read_bytes():
            problems.append(f"site/data/{name} is not examples/{source}")
    wrapped = (SITE_DATA / "pendulum.js").read_text()
    inner = wrapped[wrapped.index("{"):wrapped.rindex("}") + 1]
    pendulum = (EXAMPLES / "numexpr-edsl/viz/public/double-pendulum.json").read_text()
    if json.loads(inner) != json.loads(pendulum):
        problems.append("site/data/pendulum.js is not the committed double-pendulum.json")
    known = set(SITE_COPIES) | {"pendulum.js", "lorenz.js"}
    for extra in sorted(p.name for p in SITE_DATA.iterdir() if p.name not in known):
        problems.append(f"site/data/{extra}: nothing in this lane says where it comes from")
    if problems:
        raise Failed("\n".join(problems))
    return [f"{len(SITE_COPIES) + 1} files are the committed copies",
            "lorenz.js is NOT CHECKED here: it is written on Node by "
            "numexpr-edsl/node DumpOrbit, which this lane does not yet run"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="examples to check (default: all)")
    ap.add_argument("--record", action="store_true",
                    help="rewrite the committed copies of the NAMED examples from this run")
    ap.add_argument("--strict", action="store_true", help="a NOT RUN fails the lane")
    ap.add_argument("--list", action="store_true", help="list the examples and exit")
    args = ap.parse_args()

    by_name = {d.name: d for d in DEMOS}
    if args.list:
        for d in DEMOS:
            print(d.name)
        return 0
    unknown = [n for n in args.names if n not in by_name]
    if unknown:
        print(f"unknown example(s): {', '.join(unknown)}; see --list", file=sys.stderr)
        return 2
    if args.record and not args.names:
        print("--record needs the examples named: it rewrites committed files", file=sys.stderr)
        return 2
    chosen = [by_name[n] for n in args.names] if args.names else DEMOS

    logs = ROOT / "examples" / ".demo-logs"
    logs.mkdir(exist_ok=True)
    ok, failed, not_run = [], [], []

    for demo in chosen:
        print(f"==> {demo.name}", flush=True)
        began = time.time()
        try:
            for line in check_demo(demo, args.record, logs):
                print(f"    {line}")
            print(f"    OK ({time.time() - began:.0f} s)")
            ok.append(demo.name)
        except NotRun as why:
            print(f"    NOT RUN: {why}")
            annotate("warning", f"demo lane: {demo.name} NOT RUN: {why}")
            not_run.append(demo.name)
        except Failed as why:
            for line in str(why).splitlines():
                print(f"    {line}")
            print(f"    FAILED (log: {(logs / (demo.name + '.log')).relative_to(ROOT)})")
            annotate("error", f"demo lane: {demo.name} FAILED")
            failed.append(demo.name)

    if not args.names:
        print("==> site/data")
        try:
            for line in check_site_copies():
                print(f"    {line}")
            ok.append("site/data")
        except Failed as why:
            for line in str(why).splitlines():
                print(f"    {line}")
            print("    FAILED")
            failed.append("site/data")

    print()
    print(f"demo lane: {len(ok)} ok, {len(failed)} failed, {len(not_run)} not run"
          + (f"  (failed: {', '.join(failed)})" if failed else "")
          + (f"  (not run: {', '.join(not_run)})" if not_run else ""))
    if failed or (args.strict and not_run):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
