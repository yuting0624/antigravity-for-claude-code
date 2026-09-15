#!/usr/bin/env python3
"""Guard: every benchmark table quoted in the docs is regenerated from its aggregate.

Usage: check-bench-claims.py <doc.md> [<doc.md> ...]

A doc quotes benchmark numbers only inside a block delimited by

    <!-- bench:table run=<run-id> kind=<arms|size|paired|judge> -->
    ...
    <!-- /bench:table -->

This script renders that block again from bench/results/<run-id>/aggregate.json (via
bench/harness/analyze.render_block) and fails if the text differs, so a number in README
or docs/BENCHMARK.md can never drift from the record behind it. A doc with no markers
passes: the guard is about quoted numbers, not about requiring them.

Exit 0 when every block matches, 1 on any difference or a missing aggregate, 2 on usage.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "bench", "harness"))

OPEN_RE = re.compile(r"<!-- bench:table run=([A-Za-z0-9._-]+) kind=([a-z_]+) -->\n")
CLOSE = "<!-- /bench:table -->"


def check(path: str) -> list:
    import analyze  # noqa: E402
    from common import RESULTS_DIR  # noqa: E402
    text = open(path, encoding="utf-8").read()
    problems = []
    pos = 0
    found = 0
    while True:
        m = OPEN_RE.search(text, pos)
        if not m:
            break
        end = text.find(CLOSE, m.end())
        if end == -1:
            problems.append("%s: unclosed bench:table block for run %s" % (path, m.group(1)))
            break
        found += 1
        run_id, kind = m.group(1), m.group(2)
        agg_path = os.path.join(RESULTS_DIR, run_id, "aggregate.json")
        if not os.path.isfile(agg_path):
            problems.append("%s: no aggregate for run %s (%s)" % (path, run_id, agg_path))
        else:
            import json
            agg = json.load(open(agg_path, encoding="utf-8"))
            want = analyze.render_block(agg, kind).strip()
            got = text[m.end():end].strip()
            if want != got:
                problems.append("%s: bench:table run=%s kind=%s differs from aggregate.json\n--- expected\n%s\n--- found\n%s" % (path, run_id, kind, want, got))
        pos = end + len(CLOSE)
    return problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    problems = []
    for p in argv[1:]:
        problems.extend(check(p))
    for pr in problems:
        print("FAIL:", pr)
    if not problems:
        print("ok: every bench:table block matches its aggregate.json")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
