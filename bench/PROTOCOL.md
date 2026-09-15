# Pre-registered protocol — real-PR replay benchmark

Status: **frozen on 2026-09-15 before the full run** (git tag `bench/protocol-v1`; the tag's
commit is recorded in every run's `versions.protocol_sha` via `manifest.json` and in
`docs/BENCHMARK.md`). Nothing below changes while the run is in progress; deviations are
logged in BENCHMARK.md, never silently applied. The pilot that calibrated it is described
in BENCHMARK.md.

**Full run**: 4 arms × 8 tasks × 3 repetitions = 96 runs, two lanes on one machine, queue
seed 20260914, run id `full`, started 2026-09-15. Judging and analysis follow with the
seeds named below.

## Question

On realistic feature work in public Go repositories, does "Claude Code + this plugin,
implementation delegated to agy (Gemini Flash)" cost less per *successful* task than
"Claude Code alone", without lowering quality? Where is the break-even by task size?

## Arms

`solo-opus` (reference), `solo-sonnet`, `hybrid-inst`, `hybrid-forced` — definitions in
`arms.json`, appendices in `prompts/`. Conductor `claude-opus-5[1m]` (Sonnet 5 in
`solo-sonnet`), `--effort high`, one verification-only Bash policy for all arms
(`policy/`, `hooks/bash-gate.py`), `WebFetch`/`WebSearch` disallowed, `GOPROXY=off`,
no git remote, isolated `CLAUDE_CONFIG_DIR`, plugin loaded only through `--plugin-dir`
at a pinned SHA. Executor default tier `flash` = Gemini 3.8 Flash (High).

## Tasks

Merged PRs from caddyserver/caddy, cli/cli, grafana/k6 and sourcegraph/zoekt, merged after 2026-07-01;
each verified by `bench.py curate verify` (hidden tests fail at base, pass 3/3 at the
target commit, suite timing recorded; environment failures and flaky tests recorded in
`task.json` and skipped in the suite gate, never counted as hidden tests). Prompts are
requirement-only, linted for leaked identifiers and paths. Size classes by the author's
non-test added lines: small < 100, medium 100–600, large ≥ 700.

| id | repo | PRs | class | status |
|---|---|---|---|---|
| caddy-7877 | caddyserver/caddy | #7877 | small | verified (smoke task) |
| caddy-7995 | caddyserver/caddy | #7995 | small | verified |
| caddy-7888 | caddyserver/caddy | #7888 | medium | verified |
| caddy-7913 | caddyserver/caddy | #7913 | medium | verified (pilot) |
| cli-14136 | cli/cli | #14136 | medium | verified |
| k6-6169 | grafana/k6 | #6169 | large | verified (pilot) |
| cli-attach | cli/cli | #14177–#14184 | large | verified |
| zoekt-1105 | sourcegraph/zoekt | #1105 | large | verified |

Rejected during curation: caddy #7858 (hidden tests return early off Windows and pass at
base); cli #14179 alone (its eight-PR stack landed as one merge, so it is not isolable).
Environment note: `TMPDIR` is pinned to a plain directory for every run because macOS's
default temp dir sits behind the `/var -> /private/var` symlink, which failed one zoekt
test for the author's own code (measured; fixed for all arms alike).

## Design of one run

`bench/README.md` describes the pipeline. Fixed per run: identical task prompt, identical
caps per size class across arms, cold start (no run of the same arm within 300 s of the
previous one on either lane; `first_turn_cache_read` recorded as ground truth), the PR's
test files restored over the agent's tree before scoring, `pass := build && vet &&
hidden tests && full suite`.

Caps (from the pilot; identical across arms):

| class | max_budget_usd | max_turns | wall_s |
|---|---|---|---|
| small | 8 | 80 | 2,700 (45 min) |
| medium | 30 | 150 | 9,000 (150 min) |
| large | 75 | 250 | 14,400 (240 min) |

Set from the pilot so that no cap binds in practice (the pilot's 60/100-minute walls cut
both hybrid-forced runs while their trees already passed; those runs are failures under
the rule below, and the walls were the pilot's mistake, not the arm's). A run that hits
any cap counts as a failure; `tree_pass` is recorded separately.

Further rules fixed after the pilot: `go vet` is judged relative to the base commit
(findings the author's own tree already has, recorded per task by `curate vetbase`, are
not the agent's — k6 has two under Go 1.27); Go runs with `-mod=readonly` so no `go`
command can rewrite `go.mod`/`go.sum`; the tree-fingerprint hook records the changed file
list, and a `go` command whose only change is `go.mod`/`go.sum` is attributed to the
toolchain, not to Claude; every hybrid checkout is registered as an agy project before
the run (`agy --new-project -p /model`, zero-turn) because agy otherwise runs in its
last project root.

## Metrics

Primary: **cost-of-pass** = Σ total $ ÷ passes, per arm and per size class, where total $
= Claude Code's list-price `modelUsage.costUSD` + the Gemini side priced from
`AGY_USAGE_LOG` as `input×in + output×out + cache_read×cached_in` with
`bench/prices.lock.json`. Secondary: pass rate (hidden and full), median cost among
passes with range, wall-clock, turns, delegations, write attribution, judge scores.

Paired analysis: per task, cost-of-pass ratio arm ÷ `solo-opus`; task-level bootstrap
(resample tasks with replacement, 10,000 draws, seed 20260914); 95% CI reported with
the point estimate; undefined draws (an arm with zero passes) reported, never dropped.

Bill reconciliation: for each quiet run window, SKU sums from the GCP billing export
against the computed totals, % gap per model family.

## Hypotheses

- **H1 (cost)**: on large tasks, `hybrid-forced` cost-of-pass ≤ 0.8 × `solo-opus`;
  claimed only if the 95% CI of the paired ratio lies below 1.0.
- **H2 (quality, non-inferiority)**: each hybrid arm's pass rate ≥ `solo-opus` − 10
  percentage points, and its judge mean ≥ `solo-opus` − 0.3 on both judge families.
- **H3 (mechanism)**: `hybrid-inst` shows ≥ 1 delegation and `writes.agy > 0` in ≥ 80% of
  its runs; below that it is reported as "baseline wearing a hat" and excluded from H1/H2
  claims.
- Secondary: break-even curve (ratio per size class); `solo-sonnet` versus the hybrids on
  cost-of-pass and quality; wall-clock deltas.

## Outcome classes and reruns

- `pass`; `fail` (tests, caps, wall-clock, early stop) — never rerun.
- `infra` (`AGY_SIGNAL` `QUOTA_EXHAUSTED`/`AUTH_REQUIRED`/`MODEL_UNAVAILABLE`, wrapper exit
  10/11/13/14, Vertex 429/529 with zero tool calls, harness error, all delegations dying
  in < 5 s) — retried at most twice; every attempt kept and counted.
- `excluded` (Claude web tool call, executor web access in a brain transcript, a Claude
  shell write in `hybrid-forced`) — reported per arm with the reason.
- `hidden_test_tampered` counts as `fail`. Warm starts are kept and reported; a
  sensitivity analysis without them is included.

## Judging

Blinded single-candidate scoring on six axes (1–5) by Claude Fable 5.1 (not an arm
model) and Gemini 3.1 Pro through the plugin wrapper; the author's non-test patch and an
empty patch are scored unlabelled. Validity thresholds: the empty patch scores ≤ 1.5 with
every judge on every task, else that judge's scores for the task are void; author rank
distribution, inter-judge Spearman (pooled only if ≥ 0.4), % within one point, and
point-biserial against `pass` are all reported.

## Stopping rules

Fix before continuing if the pilot yields 0/2 `hybrid-forced` passes or a run's Claude
accounting fails to reconcile (result vs transcript > 2%). Abort the full run if
infrastructure failures exceed 30% of attempts in any arm, if spend passes 1.5× the
pilot-based estimate, or if the empty patch scores ≥ 2.0 with either judge.

## What is published

`docs/BENCHMARK.md` (tables regenerated from `aggregate.json`, guarded by
`tests/check-bench-claims.py`), every `run.json`, `patch.diff` and judge record under
`bench/results/<run-id>/`, the task definitions, this protocol, and the sha256 of the raw
transcript tarball. Parity or a loss is published the same way as a win.
