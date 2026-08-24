#!/usr/bin/env python3
"""Fail when a file tells the reader that `--sandbox` contains the agent.

It does not. Measured on macOS with agy 1.1.19: under `--yolo`, a write to an absolute
path outside `--dir` succeeded, `id` ran and returned a real uid, and curl reached the
network — identical with and without the flag. Four documents were recommending it "for
containment" when 0.25.1 went to look.

This is a security claim, which is why it gets a checker rather than a habit. Telling
someone a flag confines an agent that it does not confine is the worst direction for a
documentation error to fail in.

SENTENCES, after joining wrapped lines — and adjacent sentence PAIRS as well. Four rules
were tried and each of the first three was killed by a mutation, not by reading:

  * per line, negation anywhere on it: the measurement text pasted after a claim says
    "it is not those", which exempted a re-added "adds containment";
  * per line, negation adjacent to the word: missed a claim split across a wrap, which
    is how prose is written;
  * two-line windows: caught the wrap, then exempted a bad sentence sitting beside a
    good one, because the neighbour's negation satisfied the whole window;
  * single sentences: fixed that, and missed a claim spread over two of them — "Add
    --sandbox for isolation. It contains the untrusted commands."

So both passes run. A sentence is judged with its own negation or none, and each
adjacent pair is judged too. Either firing is enough. Neither subsumes the other: pairs
alone re-admit the beside-a-good-one bug, sentences alone miss the split claim.

WHAT IT DOES NOT CATCH, deliberately: a claim spread across THREE or more sentences.
A window of N is always beatable at N+1, so widening it is a race the checker cannot
win, and each widening costs a false-positive surface — the pair pass already had to be
paired with the single pass to avoid one. This is a guard against drift, not a proof.
Read the prose when you change it.
"""
import re
import sys

# The claim and its negation, e.g. "--sandbox is not containment", "does not contain".
# The negation has to sit next to the word: an "is not" elsewhere in the sentence is
# about something else, and letting it exempt the sentence is how the first version of
# this rule passed a re-added "adds containment".
# Contractions count. Requiring the literal word would flag "--sandbox doesn't contain
# the agent" — a correct sentence — which is the opposite failure and the one that makes
# a checker get deleted. Reviewers caught it.
NEGATED = re.compile(r"(?:\bnot\b|n't|\bnever\b)[^.]{0,20}contain", re.I)
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


def claims(sent):
    """True when this text asserts containment without negating it."""
    return bool(SANDBOX.search(sent) and CONTAIN.search(sent) and not NEGATED.search(sent))


def problems(path):
    """Single sentences AND adjacent pairs. The two catch different shapes and neither
    subsumes the other, so both run and either one is enough to flag.

    A pair alone re-admits the bug the sentence split fixed — a bad sentence beside a
    good one, exempted by the neighbour's negation. A sentence alone misses a claim
    spread over two of them ("Add --sandbox for isolation. It contains the commands."),
    which is what review found here. Running both costs one extra pass.
    """
    sents = sentences(open(path).read())
    bad, seen = [], set()

    def add(line_no, text):
        if line_no not in seen:
            seen.add(line_no)
            bad.append((path, line_no, text[:110]))

    for line_no, sent in sents:
        if claims(sent):
            add(line_no, sent)
    for (line_no, a), (_, b) in zip(sents, sents[1:]):
        if claims(a + " " + b):
            add(line_no, (a + " " + b))
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
