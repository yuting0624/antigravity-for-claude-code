# Benchmark: Claude Code alone vs Claude Code + this plugin on real pull requests

_Status: pilot complete; full run not started. Every table on this page is regenerated from
`bench/results/<run-id>/aggregate.json` by `tests/check-bench-claims.py`; a number that
is not inside a `bench:table` block is not a measurement._

## The question

Does delegating implementation work to agy (Gemini Flash) through this plugin cost less
per **successful** task than Claude Code alone, without lowering quality — and where is
the break-even by task size? The repo's own playbook predicts parity on repo-editing
work; this study is designed to find the size at which that stops being true, if it does,
and to publish the answer either way.

## How it is measured (summary; protocol in `bench/PROTOCOL.md`)

- **Tasks**: merged pull requests from public Go repositories (caddyserver/caddy, cli/cli,
  grafana/k6, sourcegraph/zoekt), merged after 2026-07-01 — after the models' training cutoffs. A task is the
  repository at the PR's parent commit plus the PR's test files; the requirement is a
  20–30 line prompt written from the PR description without naming files or identifiers
  the author introduced (linted). Every task is verified: the hidden tests fail at the
  base commit and pass three times in a row at the merge commit.
- **Arms**: `solo-opus` (reference), `solo-sonnet`, `hybrid-inst` (plugin loaded, prompt
  asks for delegation, Claude keeps its file tools), `hybrid-forced` (same, but Claude has
  no Edit/Write; agy is the only way to change a file). One verification-only Bash
  policy in every arm, identical caps per size class, identical prompts, cold starts.
- **Outcome**: the PR's test files are restored over the agent's tree (tamper check first),
  then build, vet, hidden tests, full suite, gofmt. `pass` needs all of them.
- **Cost**: Claude Code's list-price `modelUsage.costUSD` plus the Gemini side priced from
  the wrapper's `AGY_USAGE_LOG` (`input×in + output×out + cache_read×cached_in`, a lower
  bound). Metric: cost-of-pass = total spend ÷ passes. Both sides are pay-as-you-go on
  one GCP project here and are reconciled against its billing export.
- **Attribution**: a hook fingerprints the working tree around every tool call, so each
  change is attributed to a Claude file tool, a Claude shell command, or agy.
- **Quality review**: blinded single-candidate scoring on six axes by Claude Fable 5.1
  and Gemini 3.1 Pro, with the author's patch and an empty patch mixed in unlabelled.

## Tasks

| id | repo | PRs | class | author code lines / files | hidden test files |
|---|---|---|---|---|---|
| caddy-7877 | caddyserver/caddy | [#7877](https://github.com/caddyserver/caddy/pull/7877) | small | 52 / 1 | 1 |
| caddy-7995 | caddyserver/caddy | [#7995](https://github.com/caddyserver/caddy/pull/7995) | small | 57 / 4 | 1 |
| caddy-7888 | caddyserver/caddy | [#7888](https://github.com/caddyserver/caddy/pull/7888) | medium | 176 / 1 | 1 |
| caddy-7913 | caddyserver/caddy | [#7913](https://github.com/caddyserver/caddy/pull/7913) | medium | 570 / 10 | 2 |
| cli-14136 | cli/cli | [#14136](https://github.com/cli/cli/pull/14136) | medium | 199 / 3 | 5 |
| k6-6169 | grafana/k6 | [#6169](https://github.com/grafana/k6/pull/6169) | large | 1,364 / 16 | 13 |
| cli-attach | cli/cli | [#14177–#14184](https://github.com/cli/cli/pull/14186) | large | 2,242 / 22 | 22 |
| zoekt-1105 | sourcegraph/zoekt | [#1105](https://github.com/sourcegraph/zoekt/pull/1105) | large | 749 / 4 | 4 |

Curation notes are in each `bench/tasks/<repo>/<id>/task.json` (`verify`): k6-6169 skips
three HTTP/2 tests that fail 3/3 with the author's own patch on this machine and drops one
hidden test that flaked 1/6. Rejected: caddy #7858 (Windows-only tests pass at base),
cli #14179 alone (not isolable from its stack).

## Pilot (2026-09-14/15; n = 1 per cell — calibration, not a claim)

**Smoke, small task caddy-7877, all four arms:**

<!-- bench:table run=smoke kind=arms -->
| arm | runs | pass | cost-of-pass $ | median $ among passes (min–max) | Claude $ | Gemini $ | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced | 1 | 1/1 | 1.34 | 1.34 (1.34–1.34) | 1.06 | 0.28 | 478.80 | 19 | 2 (0) | 2 | 0 | 0 |
| hybrid-inst | 1 | 1/1 | 1.41 | 1.41 (1.41–1.41) | 1.05 | 0.36 | 594.70 | 23 | 1 (0) | 2 | 0 | 0 |
| solo-opus | 1 | 1/1 | 0.93 | 0.93 (0.93–0.93) | 0.93 | 0.00 | 241.90 | 15 | 0 (1) | 0 | 0 | 0 |
| solo-sonnet | 1 | 1/1 | 0.72 | 0.72 (0.72–0.72) | 0.72 | 0.00 | 339.60 | 14 | 0 (1) | 1 | 0 | 0 |
<!-- /bench:table -->

**Pilot, medium caddy-7913 and large k6-6169, `solo-opus` vs `hybrid-forced`:**

<!-- bench:table run=pilot kind=arms -->
| arm | runs | pass | cost-of-pass $ | median $ among passes (min–max) | Claude $ | Gemini $ | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced | 1 | 0/1 | — | — (—–—) | 5.72 | 3.24 | 3600.20 | 40 | 8 (0) | 0 | 0 | 1 |
| solo-opus | 2 | 2/2 | 8.72 | 8.72 (4.76–12.68) | 17.45 | 0.00 | 1302.85 | 85.50 | 0.00 (2) | 4.50 | 0 | 0 |
<!-- /bench:table -->

<!-- bench:table run=pilot kind=size -->
| arm | size | runs | pass | cost-of-pass $ | median $ among passes | wall med s |
|---|---|---|---|---|---|---|
| hybrid-forced | medium | 1 | 0/1 | — | — | 3600.20 |
| hybrid-forced | large | 0 | 0/0 | — | — | — |
| solo-opus | medium | 1 | 1/1 | 4.76 | 4.76 | 797.70 |
| solo-opus | large | 1 | 1/1 | 12.68 | 12.68 | 1808.00 |
<!-- /bench:table -->

What the pilot established, and what it changed:

- Both `hybrid-forced` runs were **killed by the pilot's wall caps** (60 min medium,
  100 min large) with trees that already passed the hidden tests and the full suite. Under
  the protocol a capped run is a failure, so their cost-of-pass is undefined here; their
  spend is nevertheless known exactly from the transcripts: **$8.96** (Claude $5.72 +
  Gemini $3.24) on the medium task versus **$4.76** for `solo-opus`, and **$20.60**
  (Claude $16.05 + Gemini $4.55) versus **$12.68** on the large task. Wall-clock ran
  4.5× and 3.3× longer. The delegations themselves took 37 and 62 minutes of agy time
  (8 and 14 calls; one failed, three hit agy's 10-minute print timeout). The full-run caps
  were set from these numbers so that none binds.
- On these two tasks the hybrid's **Claude side alone cost more than the solo run**:
  orchestration (reading to write specifications, verifying) churns the prompt cache —
  1.6 M cache-write tokens versus 0.44 M for solo on the large task.
- `go vet` failed for both arms on k6 in files neither touched; the base commit has the
  same two findings under Go 1.27. The vet gate is now relative to the base commit and
  both records were re-accounted (`solo-opus` passes; the hybrid stays a capped failure).
- The large hybrid run carries `claude_side_write_in_forced_arm`: a tree change during a
  `go doc` call 74 s in, before any delegation. The pilot ran Go with `-mod=mod`, which lets
  `go` commands rewrite `go.mod`/`go.sum`; the trace then recorded only a digest, so the
  files cannot be named after the fact. The full run uses `-mod=readonly` and the hook
  now logs the changed file list, which makes that classification possible.
- Every accounting cross-check held: Claude Code's `total_cost_usd` versus the frozen
  price deck within 0.03 percent, transcript usage versus the result object within
  tolerance, every `AGY_USAGE` line joined by its own `model`/`tier` fields, no warm starts.

## Full run

Started 2026-09-15 02:43 UTC: 96 runs, two lanes, protocol tag `bench/protocol-v1`.
Results will appear here as `bench:table` blocks when the run completes.

### Deviations log (kept as the run proceeds)

- 02:43Z — lane A relaunched detached 24 s into its first item (launcher change); the
  item was rerun; the partial attempt is kept as `interrupted`.
- 08:20Z — the laptop slept (battery, lid) during two running items; both were rerun
  as `suspended` and a separate retry budget was introduced for sleep interruptions
  (`bench/harness/schedule.py`). Spend on interrupted attempts is recorded but not
  part of any arm's numbers.
- 08:44Z — `k6-6169__solo-opus__r1` failed only on `websockets.TestLockingUpWithAJustGeneralCancel`,
  a test in a package the agent did not touch that passed 6/6 during curation; the
  checkout was already removed, so it **stays a failure** under the protocol. From the next
  item on, a test that fails in the full suite is rerun once in isolation and counted as a
  flake if it passes then (`full_suite.flaky_retry` in `run.json`); the final tables state
  how many runs' `pass` depended on that rule.
- 09:00Z — a second clamshell sleep (7 min) interrupted both running items; under the
  rule above they were rerun ($14.55 of attempts kept, not counted). Measured on those
  records: Claude Code retried the interrupted API call on wake and both runs had
  completed normally, so rerunning every slept run only burns money. From 10:00Z the
  wall cap counts active (monotonic) time, a run that slept but completed is kept and
  flagged (`suspended_s`), only a run that died of the sleep is rerun, and the final
  tables carry a sensitivity block without slept runs (`sensitivity_no_sleep`).
- 10:00Z–13:26Z — two harness bugs, both fixed and repaired in `queue.json` (`repairs`):
  (1) the per-run STOP check read the old lanes' `STOP` file instead of the new lanes'
  `STOP2`, so lanes C/D started four items whose run process exited at once; those
  attempts never ran and were removed from the items' histories. (2) In three hybrid
  runs that started within seconds of another session, Claude Code did not put the
  plugin's `bin/` on the agent's PATH; the agent found no `agy-delegate` and stopped with
  0 delegations. The harness now prepends the plugin's `bin/` itself, such a run is
  detected (`wrapper_not_found`, `env_failure: plugin_bin_missing`) and treated as an
  infrastructure failure. `caddy-7995__hybrid-forced__r1` was reclassified and rerun;
  the other two had already been rerun under the sleep rule.

## Versions and provenance

Claude Code 2.1.270, agy 1.2.2, Go 1.27.1, plugin 0.28.0 (`5392467`) for the hybrid
arms; prices frozen in `bench/prices.lock.json`; every run records these in `run.json`.

## What is not counted

Gemini context-cache storage (not reported by agy, so the Gemini side is a lower bound);
harness overhead (checkout, scoring); human time spent writing prompts; the cost of the
judging pass (reported separately).
