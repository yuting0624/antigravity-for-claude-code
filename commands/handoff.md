---
description: Hand a whole, test-covered task to Antigravity (agy/Gemini) and verify it only by running the tests — the one delegation shape measured cheaper than Claude Code alone.
argument-hint: "[--dir <repo>] [--tier flash|pro] [--verify \"<cmd>\"] [--tests a_test.go,b_test.go] <requirement>"
---

Hand the following task to Antigravity as a whole, through the plugin's `agy-handoff`
wrapper, and act as the **verifier only**.

Requirement: $ARGUMENTS

**Why this shape and not the usual delegation** (measured on 8 merged pull requests from
public Go repositories, 2 runs each, 2026-09; details in the repository's
`docs/BENCHMARK.md` / PR #91): delegating implementation file by file while you read the
code and write specifications cost 1.3–1.7× a solo run. Handing the *whole* task over and
verifying only by running the tests cost **0.58× a solo Opus 5 run per passing task**
(0.43× on large tasks, ≥700 changed lines; **more** than solo on small ones), 16/16 tests
passed, and the Claude side alone was 0.16×. The cost you avoid is *your reading*: every
file you open to "check" comes back as cache-read tokens on every later turn. A blinded
reviewer rated hand-off code 0.6 of 5 below a solo run (dead code, duplicated helpers,
unasked-for options) and about 0.2 below the human-merged PR — so the result gets the
human review a first draft would get, **after** the tests are green, not from you.

Do this:
1. **Decide whether to hand off at all.** Hand off when the task is a coherent feature or
   change of roughly 200+ lines with tests that define "done" (existing tests that must
   pass, or tests you write first). Do not hand off a small edit, a judgement call, or
   work without a verification command — those cost more this way, measured.
2. **Write the requirement as observable behaviour**, 10–30 lines: context, what must be
   true afterwards, constraints (language, no new dependencies, conventions), which test
   files exist and must pass unmodified, and the deliverable ("leave changes uncommitted").
   Do not name the files or identifiers the executor should create unless the tests do.
   Do **not** read the repository to write it — if you do not know the codebase, ask agy
   for a digest first (`agy-delegate --digest --dir . "…"`), or write the tests, but do not
   open source files yourself.
3. **Run it from a clean tree, on a branch**, synchronously if you are headless:
   ```
   agy-handoff --dir . --tests <test files> - <<'REQ'
   <the requirement>
   REQ
   ```
   `--verify` is detected from `go.mod` / `package.json` / `Cargo.toml` / `pyproject.toml`
   / `Makefile`; pass it explicitly when the repository's gate is something else. Expect
   **20–120 minutes** for a real feature. In an **interactive** session, Claude Code's
   Bash tool cuts a call off after its timeout — add `--background`, then poll with
   `agy-job status <id>` and collect with `agy-job result <id>`; do not touch the repository
   meanwhile. (Headless `claude -p`: run it synchronously and raise the Bash timeout.)
4. **Do not read the diff while it runs, and do not edit files afterwards.** The wrapper
   runs the verification command itself, sends at most one fix-up delegation quoting the
   failing output verbatim, runs it again, and checks that the named test files were not
   modified (exit 6 if they were). Your job is to read its report: `PASS` / `FAIL` /
   `TEST FILES MODIFIED`, the delegation count, the change summary, what the executor said.
5. **Report** the outcome in a few lines and hand the diff to the human as a first draft:
   what to look for is dead code, helpers duplicated beside an existing library, options
   nobody asked for, mismatched import grouping. If it failed, decide between one more
   hand-off with a sharper requirement (say what the failure told you) and taking over —
   do not patch the executor's work by hand and call it a hand-off.

Remember the measured boundaries: small tasks lose money here; the arm took 3–4× the
wall-clock of a solo run; and asking the executor to review its own diff afterwards
changed the review score by 0.07 for about $1 a run — skip that.
