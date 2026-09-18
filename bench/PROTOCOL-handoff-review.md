# Pre-registered follow-up 2 — the hand-off arm with a self-review pass

Status: **frozen before any run** (git tag `bench/protocol-handoff-review-v1`, 2026-09-18).
Adds one arm on top of `PROTOCOL-handoff.md`; nothing else changes.

## Why

The hand-off arm passed 16/16 at 0.58× `solo-opus`, but the blinded Claude judge scored its
patches 0.61 below `solo-opus` (3.42 vs 4.02), past the pre-registered 0.3 margin, with the
same rationales on every large task: dead code and unused fields, helpers re-implemented
beside a library already in `go.mod`, options nobody asked for, mismatched import grouping.
Those are things a reviewer sees in the diff. The cheapest reviewer is the executor itself
in a fresh conversation with a fixed checklist: it costs no Claude tokens (the conductor
still reads nothing) and, for a user on an Antigravity plan, nothing at all. The question
is whether that pass recovers the judge score and what it adds to the bill.

## Arm

`hybrid-handoff-review`: identical to `hybrid-handoff` (same tools, gate, caps, 135-minute
Bash timeout, `--tier flash`) with an appendix that adds, once the tests pass, exactly one
review delegation to agy in a new conversation (`--timeout 60m`) carrying a fixed
eight-point checklist and the requirement (`prompts/hybrid-handoff-review-appendix.md`),
then verification again, and at most one fix-up delegation if the review broke the tests.
Expected delegations 2–3, at most 4. The conductor never reads the diff. The checklist was
written from the Claude judge's rationales on the hand-off run; the reviewer never sees the
judge rubric.

Reference arms: `solo-opus` and `solo-sonnet` from run `full`, `hybrid-handoff` from run
`handoff` (same tasks, same pinned Claude Code 2.1.272 and plugin `5392467`, same price
lock; agy's self-updates are recorded per run). Merged by
`bench.py analyze --run-id handoff-review --include "full:solo-opus,solo-sonnet;handoff:hybrid-handoff" --also-ref hybrid-handoff`.

## Size

8 tasks × 2 repetitions = 16 runs, two lanes, queue seed 20260914, run id `handoff-review`.
Expected cost $100–160 plus about $25 of judging; 8–12 hours of mains-powered machine time.
Lanes run under launchd, start nothing on battery, and a run that slept is rerun as before.

## Hypotheses

- **H6 (quality recovered)**: judge mean ≥ `solo-opus` − 0.3 under **both** judges (the H5
  test re-run on this arm). Secondary: the paired per-task difference in Claude-judge mean
  against `hybrid-handoff` is positive with its task-level bootstrap 95% CI above 0.
- **H7 (cost still lower)**: cost-of-pass ≤ 0.8 × `solo-opus` at the pre-registered deck
  with the paired 95% CI below 1; reported also at billed rates, Claude-side-only, and as
  the added cost over `hybrid-handoff` per size class.
- Pass rate ≥ `solo-opus` − 10 pp. If the pass rate fails, neither H6 nor H7 is claimed. If
  H6 fails, H7 is reported but the arm is not called quality-neutral, as for the hand-off arm.
- Mechanism, reported: delegations per run; runs where the review broke the tests; the
  reviewer's own summary of what it changed. The pre-review tree is not captured (the
  conductor cannot read it), so recovery is measured on the final patch only.

## Judges

The same two judges, the same blinding, the same anchors. The reviewer is a Gemini model
and one judge is a Gemini model: a rise on the Gemini judge alone is discounted; the Claude
judge carries H6.

## Outcome classes, reruns, exclusions, stopping

As in `PROTOCOL.md`: caps count as failures, sleep and environment deaths are reruns,
executor web access excludes the run, the run stops at n = 2 per task, nothing is rerun for
its result.

## What is published

The same artefacts under `bench/results/handoff-review/`, a results section in
`docs/BENCHMARK.md` with tables regenerated from its `aggregate.json`, and the comparison
against `solo-opus`, `solo-sonnet` and `hybrid-handoff` on the three cost bases and both
judges — whatever the outcome.
