---
name: plugin-review
description: Review criteria for the Antigravity for Claude Code plugin — a bash + markdown Claude Code plugin that delegates work to Google's Antigravity CLI (`agy`).
---

# What this repository is

A Claude Code plugin, written in **bash and markdown**, that hands well-scoped work to a
second AI (Google's Antigravity CLI, `agy`, running Gemini) and verifies the result. There
is almost no application code: the artefacts are shell wrappers, hooks, a skill document,
and slash-command definitions. Review it accordingly — the risks live in shell semantics,
in a security gate, in a set of machine-readable contracts, and in documentation that makes
claims about a fast-moving upstream CLI.

CI already runs the test suite, `shellcheck --severity=error`, and `claude plugin validate`.
Do not repeat those. Everything below is what CI cannot check.

# Contracts that must not drift

These are consumed by other programs, not just read by humans. A change that breaks one is a
break for callers even when every test passes.

**Exit codes** — `scripts/agy-delegate.sh` and `scripts/agy-job.sh` promise:

```
0 ok · 1 usage · 2 agy failed · 3 empty · 10 quota · 11 auth · 12 timeout
13 agy missing · 14 model unavailable · 15 permission denied
```

The same table appears in `docs/TROUBLESHOOTING.md` and in `skills/antigravity/SKILL.md`. If
a diff adds, removes or repurposes a code, all three move together or it is a bug.

**Machine-readable stderr lines** — `AGY_SIGNAL {...}` (a classified failure) and
`AGY_USAGE {...}` (executor token accounting). Both must stay single-line and valid JSON;
orchestrators parse them. `AGY_USAGE`'s semantics are specific and easy to get backwards:
`total = input + output`, `thinking` is *inside* `output`, and **`cache_read` is a separate
counter — not part of `total`, not a subset of `input`**. Anything that prices the Gemini
side using a different arrangement is wrong.

**Version sync** — `.claude-plugin/plugin.json` and `skills/antigravity/SKILL.md` both carry
a version. They must match.

# The security gate

`hooks/validate-delegate-bash.sh` is the **only** restriction on what the delegate subagent
is allowed to run. Any change to it deserves disproportionate scrutiny, in both directions:

- a **bypass** — a shell construct that reaches a command the gate believes it blocked
  (quoting, substitution, chained operators, pipelines it did not anticipate)
- a **false positive** — a legitimate delegation prompt the gate now refuses, which pushes
  users toward disabling it

It is designed to **fail closed**. A change that makes it fail open on a parse error or a
missing dependency is a serious regression even if it looks like robustness.

# Shell correctness

The whole product is shell, and the failure modes are the shell's:

- **Quoting and word splitting**, especially around paths and user-supplied prompts.
- **`set -euo pipefail` interactions** — a command substitution in an assignment aborts the
  script when it fails; a function called in an `if` does not. Know which one you are
  reading.
- **Exit-code propagation** through pipes, subshells and command substitution. `$?` after a
  pipeline is the last command's, and the script often needs the first's.
- **Redirection order.** Redirections apply left to right. `cmd >file 2>/dev/null` attempts
  the open while stderr is still stderr; failures leak.
- **Portability: macOS bash 3.2 and BSD userland**, not just GNU. No `declare -A`, no
  `readarray`, no GNU-only flags on `sed`/`date`/`grep`. This repo's users are heavily macOS.
- **Temp files and cleanup on every path**, including the timeout and error paths. A
  trailing `rm -f` does not run when the script is killed; a trap does.
- **Anything captured with `$(...)`** — a child that inherits stdout and outlives the command
  holds the pipe open and the substitution never returns.

# Tests

`tests/run-tests.sh` is a hand-rolled harness using a stub `agy`. Judge a new test by one
question: **would it fail against the code before the fix?** If not, it documents rather than
detects. Watch for:

- a variable reassigned between where an existing assertion sets it and where that assertion
  reads it, silently voiding the older check
- negative assertions (`grep -q X && FAIL`) on a value that may be empty, which pass for free
- a stub too permissive to exercise the branch the test claims to cover

# Documentation

This repo tracks an upstream CLI that changes fast, so the docs make dated, falsifiable
claims. Two failure modes:

- **A claim the diff contradicts.** If the code now behaves differently from what
  `README.md`, `SKILL.md`, `docs/*.md`, `commands/*.md` or `agents/*.md` says, that is a bug
  in the PR, not a follow-up.
- **A claim changed in one place only.** A behavioural statement about `agy` typically lives
  in several documents **and in runtime strings inside `scripts/*.sh`** — a warning the
  wrapper prints is documentation too, and it is the copy users actually hit. Search for the
  claim, not for the file.

Statements about `agy` behaviour should say what was verified and on which version. Flag
confident claims that were not measured.

# Cost discipline

The plugin exists to keep bulky work off the expensive model. A change that routes raw
output — full file contents, whole logs, transcripts — into the conductor's context instead
of a digest defeats the point, even when it is otherwise correct. Cost figures in docs are
estimates and should be labelled as such.

# What not to spend findings on

Style, formatting and naming preferences; anything `shellcheck` at error severity already
catches; re-litigating a documented design decision the diff is not changing. A few
high-confidence findings are worth more here than a long list.
