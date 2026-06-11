#!/usr/bin/env python3
"""Assemble site/index.html — the one long page — from the standalone example
pages, so nobody has to navigate.

The standalone pages (lorenz.html, pendulum.html, …) are the SOURCE OF TRUTH:
edit those (or partials/top.html / partials/bottom.html for the landing copy
and colophon), then re-run this script. For each page it extracts the
page-specific <style>, the <h1> + lede, the .panes block, the seam footer,
the data <script src> tags, and the inline render script — then:

  * scopes the CSS under `#ex-<name>` so .item/.solution/… can't collide,
  * prefixes every DOM id (`id="items"` → `id="<name>-items"`, ditto
    getElementById) so nine sections coexist,
  * wraps each render script in an IIFE so `const el`/`render`/… can't clash.

Usage:  python3 build-site.py        (from site/; writes index.html)
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).parent

# (page name, tier heading inserted BEFORE this section, or None)
ORDER = [
    ("lorenz", None),
    ("pendulum",
     ("Stuff you can't easily do on other runtimes", None)),
    ("differentiation", None),
    ("roots", None),
    ("optimization", None),
    ("dimensions", None),
    ("petri",
     ("Category theory, applied — AlgebraicJulia",
      'One super nice thing in the Julia ecosystem is '
      '<a href="https://github.com/AlgebraicJulia/Catlab.jl">Catlab.jl</a> — '
      '"a framework for applied and computational category theory, written '
      'in the Julia language" — and the wider AlgebraicJulia family around '
      'it. This library lets you do things like examples {NUMS} below:')),
    ("patterns", None),
    ("schema", None),
    ("migration", None),
]


def slice_between(text, start, end, inclusive=False):
    i = text.index(start)
    j = text.index(end, i)
    return text[i : j + len(end)] if inclusive else text[i + len(start) : j]


def prefix_css(css, name):
    """Scope every flat rule under #ex-<name>. Page styles are flat by
    convention (no @media / nesting) — assert rather than mis-scope."""
    out = []
    for line in css.splitlines():
        if "@" in line and "{" in line:
            sys.exit(f"{name}: page-specific CSS has an at-rule; teach "
                     f"prefix_css about it first: {line.strip()}")
        m = re.match(r"\s*([.#a-zA-Z][^{}]*)\{", line)
        if m:
            sels = ", ".join(f"#ex-{name} {s.strip()}"
                             for s in m.group(1).split(","))
            line = "  " + sels + " {" + line[m.end():]
        out.append(line)
    return "\n".join(out)


def extract(name):
    html = (HERE / f"{name}.html").read_text()
    style = slice_between(html, "<style>", "</style>")
    h1 = re.search(r"<h1>(.*?)</h1>", html, re.S).group(1).strip()
    why = re.search(r'<p class="why">(.*?)</p>', html, re.S).group(1).strip()
    panes = html[html.index('<div class="panes">'):html.index("<footer>")].rstrip()
    foot = re.search(r"<footer>(.*?)</footer>", html, re.S).group(1).strip()
    data = re.findall(r'<script src="(data/[^"]+)"></script>', html)
    scripts = re.findall(r"<script>\n(.*?)</script>", html, re.S)

    # prefix DOM ids in both the markup and the scripts
    for i in sorted(set(re.findall(r'id="([\w-]+)"', panes)), key=len, reverse=True):
        panes = panes.replace(f'id="{i}"', f'id="{name}-{i}"')
        scripts = [s.replace(f'getElementById("{i}")',
                             f'getElementById("{name}-{i}")') for s in scripts]

    return {
        "name": name, "style": prefix_css(style, name), "h1": h1, "why": why,
        "panes": panes, "foot": foot, "data": data, "scripts": scripts,
    }


def section_html(ex, num):
    return f"""  <section class="exsec" id="ex-{ex['name']}">
    <h2 class="extitle"><span class="exnum">{num}</span>{ex['h1']}</h2>
    <p class="why">{ex['why']}</p>
    {ex['panes']}
    <p class="exfoot">{ex['foot']}</p>
  </section>
"""


def tier_html(title, tagline):
    tag = f"\n    <p class=\"tagline\">{tagline}</p>" if tagline else ""
    return f"""  <div class="tierhead">
    <h2>{title}</h2>{tag}
  </div>
"""


def main():
    top = (HERE / "partials" / "top.html").read_text()
    bottom = (HERE / "partials" / "bottom.html").read_text()

    sections, styles, data_srcs, scripts, toc = [], [], [], [], []
    tier_at = {i for i, (_, t) in enumerate(ORDER) if t}
    for i, (name, tier) in enumerate(ORDER):
        num = i + 1
        ex = extract(name)
        if tier:
            # this tier spans sections num..(section before the next tier)
            nxt = min((j for j in tier_at if j > i), default=len(ORDER))
            title, tagline = tier
            if tagline:
                tagline = tagline.replace("{NUMS}", f"{num}–{nxt}")
            sections.append(tier_html(title, tagline))
        sections.append(section_html(ex, num))
        styles.append(f"  /* — {name} — */\n" + ex["style"])
        for d in ex["data"]:
            if d not in data_srcs:
                data_srcs.append(d)
        for s in ex["scripts"]:
            scripts.append(f"// — {name} —\n(() => {{\n{s}}})();")
        toc.append(f'<a href="#ex-{name}"><b>{num}</b>&hairsp;{name}</a>')

    page = top.replace("<!-- SECTION-STYLES -->", "\n".join(styles))
    page = page.replace("<!-- TOC -->", " · ".join(toc))
    page = page.replace("<!-- SECTIONS -->", "\n".join(sections))
    page += bottom
    js = ("\n".join(f'<script src="{d}"></script>' for d in data_srcs)
          + "\n<script>\n" + "\n\n".join(scripts) + "\n</script>\n")
    page = page.replace("</body>", js + "</body>")
    page = ("<!-- GENERATED by build-site.py — edit the standalone example "
            "pages and partials/, then rebuild. -->\n") + page

    (HERE / "index.html").write_text(page)
    n = len([o for o in ORDER])
    print(f"index.html: {n} sections, {len(data_srcs)} data files, "
          f"{len(scripts)} scripts, {len(page)} bytes")


if __name__ == "__main__":
    main()
