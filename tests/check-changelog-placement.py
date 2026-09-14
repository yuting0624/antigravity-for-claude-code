#!/usr/bin/env python3
"""Fail when a PR files a CHANGELOG line under a section that is already released.

It has happened twice. #77's entry landed inside `## 0.27.0`, which had shipped; 0.27.1
had to say so in its own changelog. #82 then did it again — branched before #81 added
`## 0.27.2`, merged after, and git had no reason to object because the two PRs touched
different lines of the same file. Both were found by a human reading the merged file,
and both cost a later `release:` commit that did nothing but move paragraphs.

No rule over one file can catch this. "Is this entry under a released heading?" needs to
know which lines are NEW, and CHANGELOG.md alone cannot say — the released sections and
the unreleased one are the same shape. So the check takes the base's copy of the file and
the base's plugin.json, and judges only the lines this PR adds.

Rule. An added line may sit under:
  (a) a `## x.y.z` heading whose version is absent from the base — a section this PR
      opened, which by definition has not shipped; or
  (b) the topmost heading, when its version is newer than the base's plugin.json — the
      section the next release will carry. This is the case a `release:` PR needs: #84
      moved entries into `## 0.27.2` while the base was still on 0.27.1.
Anything else is a line being added to history. Blank lines are ignored, and so is
everything above the first heading, which is the file's preamble and not an entry.

Applied to the four PRs that motivated it: #77 (into released 0.27.0) and #82 (into
0.27.0 while the base was 0.27.1) fail; #81 (opens `## 0.27.2`) and #85 (opens
`## 0.27.3` and bumps) pass. Those four are fixtures in run-tests.sh.

Two limitations, both deliberate, because the alternative is a rule that cannot be
enforced:

  * A PR stacked on another PR's branch fails. Its base already has the new heading and
    the same plugin.json, so neither (a) nor (b) holds. #86 was exactly this shape.
    Rebasing onto master does not clear it by itself once the other PR has merged: the
    base then carries both the heading and the matching plugin.json, which is why #87 —
    the rebase of #86 — still fails this check. The fix is to open the next `## x.y.z`
    heading and bump to match, which is what CONTRIBUTING asks for regardless.
  * Correcting the text of a section that has already shipped fails, and no shape of PR
    makes it pass. A `release:` PR does not: rule (b) exempts only the *newest* heading,
    so a reworded line under anything below it is still "added to history". Measured —
    base plugin.json 0.27.0, newest heading 0.27.1, one line reworded under `## 0.26.0`
    is rc 1 — and pinned by a fixture, because an earlier draft of this docstring claimed
    the `release:` escape existed. It does not, and nothing in the diff distinguishes a
    deliberate correction from the mistake this exists to catch. The escape is social
    rather than mechanical: this is not a required status check, so a maintainer who
    means the edit merges over the red line and says in the PR body that it is deliberate.
"""
import difflib
import re
import sys

HEADING = re.compile(r"^##\s+(\d+)\.(\d+)\.(\d+)(?:\D|$)")


def version_of(line):
    """The (major, minor, patch) a `## x.y.z` heading names, or None.

    The trailing group is deliberately loose: `## 0.25.0 — security` is a real heading in
    this file, so the version is the identity and the prose after it is not.
    """
    m = HEADING.match(line)
    return tuple(int(g) for g in m.groups()) if m else None


def headings(lines):
    """[(line index, version)] for every version heading, in file order."""
    return [(i, v) for i, line in enumerate(lines)
            for v in [version_of(line)] if v is not None]


def added_indices(base_lines, head_lines):
    """Indices into head_lines of the lines this change adds.

    autojunk=False because SequenceMatcher's heuristic treats a line recurring in more
    than 1% of a long sequence as junk, and a 1200-line changelog is mostly blank lines
    and list markers — with it on, the opcodes drift and untouched paragraphs start
    looking inserted.
    """
    sm = difflib.SequenceMatcher(None, base_lines, head_lines, autojunk=False)
    out = set()
    for tag, _i1, _i2, j1, j2 in sm.get_opcodes():
        if tag in ("insert", "replace"):
            out.update(range(j1, j2))
    return out


def enclosing(hs, j):
    """The heading an added line at index j sits under, or None above the first one."""
    found = None
    for idx, ver in hs:
        if idx <= j:
            found = (idx, ver)
        else:
            break
    return found


def check(base_text, head_text, base_version):
    """[(line number, line, version, reason)] for every misplaced added line."""
    base_lines = base_text.splitlines()
    head_lines = head_text.splitlines()
    base_versions = {v for _, v in headings(base_lines)}
    hs = headings(head_lines)
    top = hs[0] if hs else None

    bad = []
    for j in sorted(added_indices(base_lines, head_lines)):
        if not head_lines[j].strip():
            continue
        here = enclosing(hs, j)
        if here is None:
            continue
        idx, ver = here
        if ver not in base_versions:
            continue
        if top is not None and idx == top[0]:
            if ver > base_version:
                continue
            reason = ("it is the newest section, but %s is not ahead of the base's "
                      "plugin.json (%s) — that version has shipped"
                      % (dotted(ver), dotted(base_version)))
        else:
            reason = "that section exists on the base branch and is not the newest one"
        bad.append((j + 1, head_lines[j], ver, reason))
    return bad


def dotted(v):
    return ".".join(str(n) for n in v)


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().split("\n")[0])
        print("usage: check-changelog-placement.py "
              "<base-changelog> <head-changelog> <base-plugin-version>")
        return 2
    base_path, head_path, base_version = argv[1], argv[2], argv[3]
    if not re.match(r"^\d+\.\d+\.\d+$", base_version):
        print("not a version: %s" % base_version)
        return 2
    with open(base_path) as f:
        base_text = f.read()
    with open(head_path) as f:
        head_text = f.read()

    bad = check(base_text, head_text, tuple(int(n) for n in base_version.split(".")))
    if not bad:
        return 0

    shown = bad[:5]
    for lineno, line, ver, reason in shown:
        text = line.strip()
        if len(text) > 90:
            text = text[:87] + "..."
        print("CHANGELOG.md:%d: added under `## %s` — %s" % (lineno, dotted(ver), reason))
        print("    %s" % text)
    if len(bad) > len(shown):
        print("...and %d more line(s)." % (len(bad) - len(shown)))
    print("")
    print("A new entry belongs under a `## x.y.z` heading this PR opens, above the "
          "newest one.")
    print("If that heading is already on the base because you branched off another PR, "
          "rebasing is not enough once it has merged — open the next version's heading "
          "and bump .claude-plugin/plugin.json and skills/antigravity/SKILL.md to match.")
    print("If you are deliberately correcting a section that has already shipped, nothing "
          "makes this pass, not even a release: PR. It is not a required check: merge over "
          "it and say in the PR body that the history edit is intended.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
