#!/usr/bin/env python3
"""
Portability index for the PureScript core libraries across the backend family.

The question nobody in the ecosystem can currently answer: *which parts of the
standard library actually work on which runtime?* It is answerable, because
portability is a computed property, not a naming convention — a module either
needs a foreign implementation or it does not, and if it does, a given backend
either supplies one or does not.

This is the artefact that replaces the idea of renaming `Data.Array` to
`JS.Data.Array` (see docs/kb/architecture/backend-companion-libraries.md in the
`docs` repo). A prefix is hand-maintained documentation that drifts. This is
generated.

Three states per (module, backend):

  portable   the module has no foreign implementation upstream, so it compiles
             on every backend by construction. Nothing to get wrong.
  provided   the module needs foreigns and this backend supplies them.
  MISSING    the module needs foreigns and this backend does NOT supply them —
             any program importing it fails. This is the column that matters.

Plus a divergence ledger: where a backend provides an implementation whose
observable behaviour differs from the JavaScript reference, taken from the
differential corpora rather than asserted.

Usage:
    bin/portability-index.py                      # markdown to stdout
    bin/portability-index.py -o INDEX.md          # write to a file
    bin/portability-index.py --root /path/to/purescript-backends
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

# ---------------------------------------------------------------------------
# The family. Each backend declares how to read its own foreign surface,
# because all three solved the same problem differently — itself a finding.
# ---------------------------------------------------------------------------

BACKENDS = [
    {
        "key": "jurist",
        "name": "Jurist",
        "runtime": "Julia",
        "repo": "purescript-julia",
        "foreigns": "src/Language/PureScript/Julia/Foreigns.hs",
        # One `Module_foreign.jl` string literal per covered module.
        "style": "per-module",
        "pattern": r'"([A-Za-z_0-9]+)_foreign\.jl"',
    },
    {
        "key": "pythia",
        "name": "Pythia",
        "runtime": "Python",
        "repo": "purescript-python",
        "foreigns": "src/Language/PureScript/Python/Foreigns.hs",
        "style": "per-module",
        "pattern": r'"([A-Za-z_0-9]+)_foreign\.py"',
    },
    {
        "key": "gnomon",
        "name": "Gnomon",
        "runtime": "Go",
        "repo": "purescript-go",
        "foreigns": "runtime/prelude.go",
        # One flat runtime file: `Module_functionName` symbols, so the covered
        # modules are recovered by longest-prefix match against known modules.
        "style": "flat-prelude",
        "pattern": r"\b((?:Data|Control|Effect|Record|Partial|Unsafe|Prim|Test)_[A-Za-z_0-9]+)\b",
    },
]

# Where to find the resolved package sources — the universe of modules the
# corpora actually depend on. The UNION of all three, not the first one found:
# the backends' test suites do not depend on the same packages, and scanning
# only one hides exactly the gaps this index exists to surface. (Gnomon's
# Test.Transformers failed on missing Effect.Exception foreigns while an
# index built from Pythia's set alone reported it 100% covered, because
# `exceptions` was not in Pythia's closure at all.)
PACKAGE_SOURCE_CANDIDATES = [
    "purescript-python/test-suite/.spago/p",
    "purescript-julia/test-suite/.spago/p",
    "purescript-go/test-suite/.spago/p",
]

# Observed divergences, mapped from the corpora's KNOWN_DIVERGENCES to the
# library module responsible. Hand-maintained because the corpus keys cases by
# test name, not by module — but each entry is a real, reproduced difference,
# not a suspicion.
DIVERGENCES = {
    "Data.String.CodeUnits": [
        (
            "pythia",
            "String indexing is by code point, not UTF-16 code unit. "
            "`length` of an astral-plane emoji is 1, not 2; `take 1` returns "
            "the whole character rather than half a surrogate pair.",
        ),
    ],
    "Effect.Exception": [
        (
            "pythia",
            "`stack` is Nothing for a constructed Error — Python attaches a "
            "traceback only once an exception has been raised, where JS "
            "captures one at construction. A caught error does carry one.",
        ),
        (
            "jurist",
            "`stack` is always Nothing — Julia has a backtrace only inside a "
            "catch, never on an exception value.",
        ),
        (
            "gnomon",
            "`stack` is always Nothing — Go has a stack only while panicking, "
            "never on an error value.",
        ),
    ],
    "Data.Int": [
        (
            "pythia",
            "`Int` is arbitrary-precision, not 32-bit wrapping. "
            "`sumTo 1e6` and `fact 20` give the mathematically correct answer "
            "where JavaScript overflows.",
        ),
    ],
}

# Packages that are infrastructure rather than library surface.
SKIP_PACKAGES = {"metadata", "prelude-docs"}


def module_name_from_path(src_root: Path, purs: Path) -> str:
    """`src/Data/Array/ST.purs` -> `Data.Array.ST`."""
    return ".".join(purs.relative_to(src_root).with_suffix("").parts)


def collect_modules(pkg_roots: list[Path]) -> dict[str, dict]:
    """Every module across the resolved package sets, with its foreign status."""
    modules: dict[str, dict] = {}
    for pkg_root in pkg_roots:
        _collect_from(pkg_root, modules)
    return modules


def _collect_from(pkg_root: Path, modules: dict[str, dict]) -> None:
    for pkg_dir in sorted(pkg_root.iterdir()):
        if not pkg_dir.is_dir():
            continue
        pkg = pkg_dir.name
        if pkg.rsplit("-", 1)[0] in SKIP_PACKAGES:
            continue
        src = pkg_dir / "src"
        if not src.is_dir():
            continue
        for purs in sorted(src.rglob("*.purs")):
            mod = module_name_from_path(src, purs)
            modules[mod] = {
                "package": pkg,
                # The upstream JS foreign sits beside its .purs with the same
                # stem — the rule the whole FFI system runs on.
                "needs_foreign": purs.with_suffix(".js").exists(),
            }


def collect_backend_coverage(root: Path, backend: dict, known: set[str]) -> set[str]:
    """Modules (dotted names) for which this backend supplies a foreign."""
    path = root / backend["repo"] / backend["foreigns"]
    if not path.exists():
        print(f"warning: {path} not found; treating {backend['name']} as empty",
              file=sys.stderr)
        return set()
    text = path.read_text(encoding="utf-8", errors="replace")
    hits = re.findall(backend["pattern"], text)

    if backend["style"] == "per-module":
        return {h.replace("_", ".") for h in hits}

    # flat-prelude: symbols are `Module_underscored_functionName`, and both
    # halves use underscores, so resolve by longest matching module prefix.
    underscored = {m.replace(".", "_"): m for m in known}
    covered: set[str] = set()
    for sym in hits:
        parts = sym.split("_")
        for cut in range(len(parts) - 1, 0, -1):
            candidate = "_".join(parts[:cut])
            if candidate in underscored:
                covered.add(underscored[candidate])
                break
    return covered


def status_for(mod: str, info: dict, backend_key: str, coverage: dict[str, set[str]]) -> str:
    if not info["needs_foreign"]:
        return "portable"
    return "provided" if mod in coverage[backend_key] else "MISSING"


def render(modules: dict[str, dict], coverage: dict[str, set[str]]) -> str:
    keys = [b["key"] for b in BACKENDS]
    out: list[str] = []
    w = out.append

    total = len(modules)
    portable = sum(1 for i in modules.values() if not i["needs_foreign"])
    foreign = total - portable

    # kb house-style frontmatter, so the generated file sits in the knowledge
    # base like anything else.
    w("---")
    w('title: "Portability index — the core libraries across the backends"')
    w("category: reference")
    w("status: generated")
    w(f"updated: {date.today().isoformat()}")
    w("audience: [anyone choosing a library for a non-JS backend, future Claudes]")
    w("---")
    w("")
    w("# Portability index — the PureScript core libraries across the backends")
    w("")
    w("**Generated** by `purescript-julia/bin/portability-index.py`. Do not edit"
      " by hand.")
    w("")
    w("Portability is a computed property, not a naming convention. A module"
      " either needs a")
    w("foreign implementation or it does not; if it does, each backend either"
      " supplies one")
    w("or does not. Everything below is read off the source of the backends and"
      " of the")
    w("resolved package set — nothing here is asserted.")
    w("")
    w("| state | meaning |")
    w("|---|---|")
    w("| **portable** | no foreign upstream — compiles on every backend by"
      " construction |")
    w("| **provided** | needs a foreign, and this backend supplies one |")
    w("| **MISSING** | needs a foreign and this backend has none — *any program"
      " importing it fails* |")
    w("")

    # ---- headline ----------------------------------------------------------
    w("## Summary")
    w("")
    w(f"Universe: **{total} modules** across"
      f" **{len({i['package'] for i in modules.values()})} packages** — the"
      " dependency closure of the")
    w("differential corpus, which is the set of libraries these backends are"
      " actually asked to")
    w(f"compile. Of those, **{portable} are portable** (no foreigns at all) and"
      f" **{foreign} need a")
    w("foreign implementation**.")
    w("")
    w("| backend | runtime | provided | MISSING | coverage of the foreign surface |")
    w("|---|---|---:|---:|---:|")
    for b in BACKENDS:
        prov = sum(1 for m, i in modules.items()
                   if i["needs_foreign"] and m in coverage[b["key"]])
        miss = foreign - prov
        pct = (100.0 * prov / foreign) if foreign else 0.0
        w(f"| {b['name']} | {b['runtime']} | {prov} | **{miss}** | {pct:.0f}% |")
    w("")
    w("The portable column is the interesting one: **it is the same for every"
      " backend**, and it")
    w("is what the differential corpus can test byte-for-byte. Everything else"
      " is a per-runtime")
    w("promise that has to be kept by hand.")
    w("")

    # ---- what is missing, per backend --------------------------------------
    w("## What is missing")
    w("")
    w("The practical answer to \"can I use this library on that runtime?\".")
    w("")
    any_missing = False
    for b in BACKENDS:
        miss = sorted(m for m, i in modules.items()
                      if i["needs_foreign"] and m not in coverage[b["key"]])
        if not miss:
            w(f"**{b['name']} ({b['runtime']})** — nothing missing from the"
              " corpus's dependency closure.")
            w("")
            continue
        any_missing = True
        by_pkg: dict[str, list[str]] = defaultdict(list)
        for m in miss:
            by_pkg[modules[m]["package"]].append(m)
        noun = "module" if len(miss) == 1 else "modules"
        w(f"**{b['name']} ({b['runtime']})** — {len(miss)} {noun}:")
        w("")
        for pkg in sorted(by_pkg):
            w(f"- `{pkg}` — " + ", ".join(f"`{m}`" for m in sorted(by_pkg[pkg])))
        w("")
    if not any_missing:
        w("Nothing is missing on any backend, within this universe. That is a"
          " stronger result")
        w("than it sounds: it means the corpus's dependency closure is fully"
          " implemented three")
        w("times over. It says nothing about libraries outside the closure —"
          " see the caveat below.")
        w("")

    # ---- divergences -------------------------------------------------------
    w("## Divergences — provided, but not identical")
    w("")
    w("A foreign implementation can exist and still not mean the same thing."
      " These are the")
    w("differences the differential corpus has actually observed and"
      " reproduced, not a list of")
    w("suspicions. They are the honest edge of the whole method.")
    w("")
    if DIVERGENCES:
        w("| module | backend | observed difference |")
        w("|---|---|---|")
        for mod in sorted(DIVERGENCES):
            for bkey, note in DIVERGENCES[mod]:
                bname = next(b["name"] for b in BACKENDS if b["key"] == bkey)
                w(f"| `{mod}` | {bname} | {note} |")
        w("")
    w("Worth noting what is *not* on that list. `Data.Array` is one of the"
      " most heavily")
    w("foreign-implemented families in the set and has **never** diverged: a"
      " contiguous")
    w("indexable sequence is universal, and JavaScript arrays map cleanly onto"
      " Python lists,")
    w("Julia `Vector`s and Go slices. Cost of implementation and depth of"
      " runtime-specificity")
    w("are different properties, and only the second one breaks portability.")
    w("")

    # ---- full table --------------------------------------------------------
    w("## Full index")
    w("")
    header = "| module | package | " + " | ".join(b["name"] for b in BACKENDS) + " |"
    w(header)
    w("|---|---|" + "---|" * len(BACKENDS))
    for mod in sorted(modules):
        info = modules[mod]
        cells = []
        for k in keys:
            s = status_for(mod, info, k, coverage)
            cells.append("·" if s == "portable" else
                         ("provided" if s == "provided" else "**MISSING**"))
        w(f"| `{mod}` | {info['package']} | " + " | ".join(cells) + " |")
    w("")
    w("`·` = portable: no foreign anywhere, so there is nothing for a backend"
      " to provide.")
    w("")

    # ---- caveats -----------------------------------------------------------
    w("## What this index does not tell you")
    w("")
    w("Stated plainly, because an index that overclaims is worse than none.")
    w("")
    w("- **Scope is the corpus's dependency closure**, not the whole registry."
      " A package")
    w("  outside it may need foreigns that no backend has. Widening the closure"
      " widens the")
    w("  index.")
    w("- **\"provided\" is not \"correct\".** It means an implementation exists."
      " The differential")
    w("  corpus tests behaviour for the modules it exercises; a provided"
      " foreign that no test")
    w("  reaches is an untested promise.")
    w("- **\"portable\" is not \"correct\" either, and this is the sharp"
      " one.** Portability is a")
    w("  property of the *source*: no foreigns, so nothing to reimplement. It"
      " says nothing")
    w("  about whether the **lowering** handles that source. `Data.Map` is"
      " portable by this")
    w("  index — `ordered-collections` ships not one foreign file — and it was"
      " nonetheless")
    w("  completely broken on Pythia for the lifetime of the backend, because a"
      " recursive")
    w("  local binding miscompiled. The suite ran green throughout. **This"
      " index measures one")
    w("  axis; the differential corpus measures the other; neither substitutes"
      " for the other.**")
    w("- **\"portable\" is a claim about compilation, not about performance.**"
      " A portable")
    w("  module may be dramatically slower on one runtime than another —"
      " measured at 70× for")
    w("  a numeric loop on Julia versus Node.")
    w("- The divergence ledger is hand-maintained from the corpora, so it is a"
      " lower bound:")
    w("  every entry is real, but absence is not proof of agreement.")
    w("")
    return "\n".join(out) + "\n"


def main() -> int:
    here = Path(__file__).resolve().parent
    default_root = here.parent.parent  # .../purescript-backends

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=default_root,
                    help="directory holding the backend repos (default: %(default)s)")
    ap.add_argument("-o", "--output", type=Path,
                    help="write markdown here instead of stdout")
    args = ap.parse_args()

    pkg_roots = [args.root / c for c in PACKAGE_SOURCE_CANDIDATES
                 if (args.root / c).is_dir()]
    if not pkg_roots:
        print("error: no resolved package set found. Run `spago build` in a "
              "backend's test-suite first, so .spago/p is populated.",
              file=sys.stderr)
        return 1

    modules = collect_modules(pkg_roots)
    if not modules:
        print(f"error: no modules found under {pkg_roots}", file=sys.stderr)
        return 1

    coverage = {b["key"]: collect_backend_coverage(args.root, b, set(modules))
                for b in BACKENDS}

    md = render(modules, coverage)
    if args.output:
        args.output.write_text(md, encoding="utf-8")
        print(f"wrote {args.output} ({len(md.splitlines())} lines, "
              f"{len(modules)} modules)", file=sys.stderr)
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
