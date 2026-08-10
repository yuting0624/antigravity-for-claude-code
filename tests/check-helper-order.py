#!/usr/bin/env python3
"""Fail when a shell function in the given script is CALLED above its definition.

bash does not hoist. Such a call is `command not found`, exit 127, and any `if`
wrapped around it takes the else branch unconditionally — so an assertion written
that way passes no matter what it was checking. It costs nothing at parse time and
nothing at review, which is why it needs a machine to notice.

The first cut matched command position with one big alternation of contexts, and
review pointed out what it left out: `elif`, a call inside a `case` branch, a brace
group. A checker that misses a shape is a false negative, which is the same defect it
exists to prevent. So the line is split into command segments and each segment's first
real word is compared — there is no list of contexts to keep complete.
"""
import re
import sys

# Anything that ends one command and begins another. `(` and `)` cover subshells and
# the `pattern)` opening a case branch; backtick and `$(` cover substitution.
SEGMENT = re.compile(r"\|\||&&|\$\(|[;&|()`{}]")

# Words that may precede a command without being one, leaving the NEXT word in command
# position: `if has x`, `elif has x`, `! has x`, `do has x`.
PREFIX = {
    "if", "elif", "then", "else", "while", "until", "do", "done", "!",
    "time", "exec", "command", "builtin", "eval", "nohup",
}


def calls(line, fn):
    """True when `fn` is the command word of some segment of `line`."""
    for seg in SEGMENT.split(line):
        words = seg.strip().split()
        i = 0
        while i < len(words) and words[i] in PREFIX:
            i += 1
        if i < len(words) and words[i] == fn:
            return True
    return False


def check(path):
    """Return [(name, call_line, definition_line)] for every use above a definition."""
    src = open(path).read().split("\n")

    defs = {}
    for i, line in enumerate(src, 1):
        m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", line)
        if m:
            defs.setdefault(m.group(1), i)

    bad = []
    for fn, dline in sorted(defs.items(), key=lambda kv: kv[1]):
        for i, line in enumerate(src, 1):
            if i == dline or line.lstrip().startswith("#"):
                continue
            if calls(line, fn):
                if i < dline:
                    bad.append((fn, i, dline))
                break
    return bad


if __name__ == "__main__":
    found = check(sys.argv[1])
    for fn, use, dline in found:
        print("%s() is called at line %d but not defined until line %d" % (fn, use, dline))
    sys.exit(1 if found else 0)
