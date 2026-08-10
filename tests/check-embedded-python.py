#!/usr/bin/env python3
"""Fail when a `python3 -c '...'` block in a shell script is cut short by a quote.

The shell string ends at the FIRST single quote after the opening one — so an
apostrophe anywhere in the program, including in a comment, silently shortens it.
Bash then parses the remainder as arguments and redirections, which is usually still
valid shell: `bash -n` passes, shellcheck passes, and the truncated program runs and
returns nothing useful. With stderr on /dev/null, as these blocks have, the caller
simply sees "no findings".

Two signals separate a truncation from a real end, and either one is enough:
  * the body ends on a comment line — where an apostrophe in prose lands
  * the body does not compile — where an apostrophe in code lands
"""
import sys

OPEN = "python3 -c '"


def problems(path):
    src = open(path).read()
    out = []
    at = 0
    while True:
        i = src.find(OPEN, at)
        if i < 0:
            return out
        start = i + len(OPEN)
        end = src.find("'", start)
        at = end + 1 if end >= 0 else start
        if end < 0:
            out.append((path, src.count("\n", 0, start) + 1, "never closed"))
            continue
        body = src[start:end]
        line = src.count("\n", 0, start) + 1
        last = body.rstrip("\n").split("\n")[-1].lstrip()
        if last.startswith("#"):
            out.append((path, line + body.count("\n"), "ends inside a comment"))
            continue
        try:
            compile(body, path, "exec")
        except SyntaxError as e:
            out.append((path, line, "does not compile (%s)" % e.msg))


if __name__ == "__main__":
    found = []
    for p in sys.argv[1:]:
        found += problems(p)
    for path, line, why in found:
        print("%s:%d: embedded python %s — a quote ended the shell string early" % (path, line, why))
    sys.exit(1 if found else 0)
