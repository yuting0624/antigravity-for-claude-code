# Pre-registered follow-up — the hand-off arm

Status: **frozen before any run** (git tag `bench/protocol-handoff-v1`, 2026-09-17). A
follow-up to `PROTOCOL.md`, not a change to it: the main study's result stands; this adds
one arm and reuses the main study's reference arms.

## Why

The main study found that delegating implementation one file at a time costs more than
Claude Code alone because the conductor still reads the repository to write specifications
and to verify, and each specification and result is new context (cache writes ×2–3, output
tokens ×0.8–1.05, 4–16 delegations, each re-reading the repository on the executor side).
The token decomposition (`docs/BENCHMARK.md`, "why") says the only way delegation can save
money on implementation is if the conductor **stops reading**: hand the whole task to the
executor once and verify by running the tests, not by reading the diff. That is the arm
tested here. It is also the configuration that matters most to users on an Antigravity
plan whose Gemini side is not metered per token: for them the Claude side is the bill.

## Arm

`hybrid-handoff`: Claude Opus 5, `--effort high`, plugin loaded, no `Read`/`Glob`/`Grep`/
`Edit`/`Write`/`Agent`, Bash restricted to build/vet/test, `gofmt -l`, read-only `git`
status/diff-stat and the wrapper (`BENCH_POLICY=strict`; file-reading commands are blocked
by the gate). The prompt appendix (`prompts/hybrid-handoff-appendix.md`) instructs: one
delegation of the requirement verbatim (`--tier flash --yolo --dir . --timeout 120m`),
then `go build && go vet && go test`, at most one fix-up delegation quoting the failing
output, then stop. Everything else — caps per size class, cold start, scoring, hidden-test
restoration, exclusion rules, judging — is as in `PROTOCOL.md`. The caps are the main
study's caps, unchanged, even though a 120-minute delegation plus a fix-up can hit the
large-task wall (240 min): a cap that binds only on the new arm biases *against* it, which
is the safe direction for a saving claim.

Reference arms: `solo-opus` and `solo-sonnet` from run `full` (same tasks, same pinned
binaries — Claude Code 2.1.272, agy 1.2.3, plugin 0.28.0 at `5392467`, same prices lock).
The analysis merges them with `bench.py analyze --run-id handoff --include full:solo-opus,solo-sonnet`
and records that provenance in the aggregate.

## Size

8 tasks × 2 repetitions = 16 runs, two lanes, queue seed 20260914, run id `handoff`.
Expected cost about $100–160 (Claude side small; one long Gemini conversation per run) plus
about $20 of judging; expected time 8–12 hours of mains-powered machine time.

## Hypotheses

- **H4 (cost)**: `hybrid-handoff` cost-of-pass ≤ 0.8 × `solo-opus` at the pre-registered
  deck, claimed only if the paired 95% CI lies below 1.0; reported also at billed rates and
  Claude-side-only (the metered-Claude, unmetered-Gemini case).
- **H5 (quality)**: pass rate ≥ `solo-opus` − 10 pp; judge means ≥ `solo-opus` − 0.3 on both
  judge families. If H5 fails, H4 is not claimed regardless of the ratio.
- Secondary: `hybrid-handoff` versus `solo-sonnet` on cost and pass rate — a cheaper
  conductor is the alternative a buyer would compare against; break-even by size class;
  delegations per run (expected 1–2; a run with more is reported as such).

## Outcome classes, reruns, exclusions, stopping

As in `PROTOCOL.md`: caps count as failures, `tree_pass` recorded separately; sleep,
network and environment deaths are reruns; executor web access excludes the run; the
run stops at n = 2 per task; nothing is rerun for its result.

## What is published

The same artefacts as the main study under `bench/results/handoff/`, a results section in
`docs/BENCHMARK.md` with tables regenerated from its `aggregate.json`, and — whatever the
outcome — the comparison against both solo arms on the three cost bases.
