#!/usr/bin/env python3
"""Fail when a shell function in the given script is CALLED above its definition.

bash does not hoist. Such a call is `command not found`, exit 127, and any `if`
wrapped around it takes the else branch unconditionally — so an assertion written
that way passes no matter what it was checking. It costs nothing at parse time and
nothing at review, which is why it needs a machine to notice.
"""
import re
import sys

src = open(sys.argv[1]).read().split("\n")

defs = {}
for i, line in enumerate(src, 1):
    m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", line)
    if m:
        defs.setdefault(m.group(1), i)

bad = []
for fn, dline in sorted(defs.items(), key=lambda kv: kv[1]):
    # A CALL is the bare name in command position. Excluded: the definition itself
    # (`name()`), any prose about it (a comment line), and any other name that merely
    # ends with these characters.
    call = re.compile(
        r"(?:^|[;&|]|\bif\s|\bthen\s|\belse\s|\bwhile\s|\buntil\s|\bdo\s|!\s|\$\()"
        r"\s*" + re.escape(fn) + r"(?![\w(])"
    )
    for i, line in enumerate(src, 1):
        if i == dline or line.lstrip().startswith("#"):
            continue
        if call.search(line):
            if i < dline:
                bad.append((fn, i, dline))
            break

for fn, use, dline in bad:
    print("%s() is called at line %d but not defined until line %d" % (fn, use, dline))
sys.exit(1 if bad else 0)
