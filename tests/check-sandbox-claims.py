#!/usr/bin/env python3
"""Fail when a file tells the reader that `--sandbox` contains the agent.

It does not. Measured on macOS with agy 1.1.19: under `--yolo`, a write to an absolute
path outside `--dir` succeeded, `id` ran and returned a real uid, and curl reached the
network — identical with and without the flag. Four documents were recommending it "for
containment" when 0.25.1 went to look.

This is a security claim, which is why it gets a checker rather than a habit. Telling
someone a flag confines an agent that it does not confine is the worst direction for a
documentation error to fail in.

SENTENCES, not lines and not two-line windows, because both of those were tried:

  * per line missed a claim split across a wrap, which is how prose is written;
  * two-line windows fixed that and then exempted a bad sentence sitting next to a good
    one — the negation from the neighbour satisfied the whole window.

Splitting on sentence boundaries after joining the lines handles both: each claim is
judged with its own negation or without one.
"""
import re
import sys

# The claim and its negation, e.g. "--sandbox is not containment", "does not contain".
# The negation has to sit next to the word: an "is not" elsewhere in the sentence is
# about something else, and letting it exempt the sentence is how the first version of
# this rule passed a re-added "adds containment".
NEGATED = re.compile(r"\bnot\b[^.]{0,20}contain", re.I)
SANDBOX = re.compile(r"sandbox", re.I)
CONTAIN = re.compile(r"contain", re.I)


def sentences(text):
    """Join wrapped lines, then split on sentence ends, keeping a line number."""
    out, buf, start = [], [], 1
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            if buf:
                out.append((start, " ".join(buf)))
                buf = []
            continue
        if not buf:
            start = n
        buf.append(line.strip())
    if buf:
        out.append((start, " ".join(buf)))

    split = []
    for line_no, para in out:
        for part in re.split(r"(?<=[.!?])\s+", para):
            if part.strip():
                split.append((line_no, part.strip()))
    return split


def problems(path):
    text = open(path).read()
    bad = []
    for line_no, sent in sentences(text):
        if SANDBOX.search(sent) and CONTAIN.search(sent) and not NEGATED.search(sent):
            bad.append((path, line_no, sent[:110]))
    return bad


if __name__ == "__main__":
    found = []
    for p in sys.argv[1:]:
        try:
            found += problems(p)
        except OSError:
            continue
    for path, line_no, sent in found:
        print("%s:~%d: describes --sandbox as containment — it is not: %s" % (path, line_no, sent))
    sys.exit(1 if found else 0)
