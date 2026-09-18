# Benchmark: Claude Code alone vs Claude Code + this plugin on real pull requests

_Status: complete (full run 2026-09-15/16; 75 runs). Every table on this page is regenerated from
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
  no Edit/Write; agy is the only way to change a file); in a pre-registered follow-up,
  `hybrid-handoff` (Claude has no file reading or editing at all: one delegation of the
  whole task, verification by running the tests). One verification-only Bash policy in
  every arm, identical caps per size class, identical prompts, cold starts.
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
| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced | 1 | 1/1 | 1.34 | 1.62 | 1.34 (1.34–1.34) | 1.06 | 0.28 / 0.56 | 478.80 | 19 | 2 (0) | 2 | 0 | 0 |
| hybrid-inst | 1 | 1/1 | 1.41 | 1.77 | 1.41 (1.41–1.41) | 1.05 | 0.36 / 0.72 | 594.70 | 23 | 1 (0) | 2 | 0 | 0 |
| solo-opus | 1 | 1/1 | 0.93 | 0.93 | 0.93 (0.93–0.93) | 0.93 | 0.00 / 0.00 | 241.90 | 15 | 0 (1) | 0 | 0 | 0 |
| solo-sonnet | 1 | 1/1 | 0.72 | 0.72 | 0.72 (0.72–0.72) | 0.72 | 0.00 / 0.00 | 339.60 | 14 | 0 (1) | 1 | 0 | 0 |
<!-- /bench:table -->

**Pilot, medium caddy-7913 and large k6-6169, `solo-opus` vs `hybrid-forced`:**

<!-- bench:table run=pilot kind=arms -->
| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced | 1 | 0/1 | — | — | — (—–—) | 5.72 | 3.24 / 6.47 | 3600.20 | 40 | 8 (0) | 0 | 0 | 1 |
| solo-opus | 2 | 2/2 | 8.72 | 8.72 | 8.72 (4.76–12.68) | 17.45 | 0.00 / 0.00 | 1302.85 | 85.50 | 0.00 (2) | 4.50 | 0 | 0 |
<!-- /bench:table -->

<!-- bench:table run=pilot kind=size -->
| arm | size | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes | wall med s |
|---|---|---|---|---|---|---|---|
| hybrid-forced | medium | 1 | 0/1 | — | — | — | 3600.20 |
| hybrid-forced | large | 0 | 0/0 | — | — | — | — |
| solo-opus | medium | 1 | 1/1 | 4.76 | 4.76 | 4.76 | 797.70 |
| solo-opus | large | 1 | 1/1 | 12.68 | 12.68 | 12.68 | 1808.00 |
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

## Full run — results (2026-09-15 02:43Z to 2026-09-16 18:21Z)

**Headline.** On eight merged pull requests from four public Go repositories, Claude
Code with this plugin delegating the implementation to agy cost **more per successful
task than Claude Code alone, at equal test outcomes, and took 3.8–4.6× the wall-clock**.
Paired on the same tasks, cost-of-pass was **1.33× `solo-opus` for `hybrid-forced`**
(95% CI 1.03–1.78) and **1.68× for `hybrid-inst`** (1.34–2.12) at the pre-registered
price deck; at the unit prices the project was actually billed (Gemini 3.8 Flash at twice
the deck's promotional rate, see below) 1.75× (1.39–2.28) and 2.08× (1.67–2.66). Every
hybrid run passed its hidden tests and the repository's full suite (16/16 and 16/16), as
did every `solo-opus` run (21/21). `solo-sonnet` cost 0.58× `solo-opus` (0.42–0.83) and
passed 17/20 — two of its failures were the turn cap with a passing tree. No size class
showed a saving. The closest to parity was the largest task, cli-attach (2,242 lines),
where `hybrid-forced` cost 0.87× `solo-opus` on n = 2 per arm.

- **H1 (cost)** — not supported: no class has a ratio below 1; the overall CIs exclude 1
  at both price bases.
- **H2 (quality)** — pass rates non-inferior (−0 pp); judge means non-inferior for
  `hybrid-inst` under both judges and for `hybrid-forced` under the Gemini judge; under
  the Claude judge `hybrid-forced` sits 0.28 below `solo-opus` (3.74 vs 4.02, margin 0.3).
- **H3 (mechanism)** — satisfied: every hybrid run delegated (median 4–5 calls) and agy
  wrote files in every one, so the hybrid numbers measure delegation, not a baseline.

Design as run: 75 counted runs over 32 task × arm cells (11 cells at n = 3, 21 at n = 2;
the operator stopped the run at n ≥ 2 per cell, see the deviations log). Two `hybrid-forced`
runs are excluded by the pre-registered rule: the executor used `search_web` to look for
the upstream file or pull request (caddy-7888 r1, zoekt-1105 r1; both had passed).

<!-- bench:table run=full kind=arms -->
| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced | 16 | 16/16 | 10.89 | 14.34 | 6.74 (0.74–38.03) | 118.98 | 55.24 / 110.49 | 2451.60 | 36.00 | 5.00 (0) | 3.00 | 0 | 0 |
| hybrid-inst | 16 | 16/16 | 13.77 | 17.06 | 6.14 (1.06–48.17) | 153.33 | 67.05 / 119.66 | 2974.25 | 59.50 | 4.00 (0) | 4.50 | 3 | 0 |
| solo-opus | 21 | 21/21 | 8.22 | 8.22 | 4.32 (0.65–40.92) | 172.55 | 0.00 / 0.00 | 653.10 | 63 | 0 (21) | 2 | 0 | 0 |
| solo-sonnet | 20 | 17/20 | 4.74 | 4.74 | 2.28 (0.46–8.83) | 80.50 | 0.00 / 0.00 | 676.40 | 69.00 | 0.00 (20) | 3.00 | 0 | 2 |
<!-- /bench:table -->
<!-- bench:table run=full kind=size -->
| arm | size | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes | wall med s |
|---|---|---|---|---|---|---|---|
| hybrid-forced | small | 5 | 5/5 | 2.40 | 3.26 | 2.93 | 924.40 |
| hybrid-forced | medium | 6 | 6/6 | 6.62 | 8.75 | 6.74 | 2451.60 |
| hybrid-forced | large | 5 | 5/5 | 24.50 | 32.14 | 24.87 | 6976.50 |
| hybrid-inst | small | 4 | 4/4 | 3.29 | 4.42 | 3.18 | 969.15 |
| hybrid-inst | medium | 6 | 6/6 | 5.84 | 7.41 | 5.90 | 2074.60 |
| hybrid-inst | large | 6 | 6/6 | 28.70 | 35.14 | 28.11 | 6580.00 |
| solo-opus | small | 5 | 5/5 | 1.98 | 1.98 | 2.17 | 399.40 |
| solo-opus | medium | 8 | 8/8 | 4.41 | 4.41 | 4.07 | 576.35 |
| solo-opus | large | 8 | 8/8 | 15.92 | 15.92 | 11.83 | 1487.95 |
| solo-sonnet | small | 5 | 4/5 | 1.98 | 1.98 | 1.32 | 485.10 |
| solo-sonnet | medium | 8 | 8/8 | 1.81 | 1.81 | 2.46 | 630.70 |
| solo-sonnet | large | 7 | 5/7 | 11.62 | 11.62 | 2.73 | 870.90 |
<!-- /bench:table -->
<!-- bench:table run=full kind=paired -->
| comparison | tasks | ratio (deck) | 95% CI | ratio (billed rates) | 95% CI | ratio (Claude side only) | 95% CI | pass-rate diff | undefined draws |
|---|---|---|---|---|---|---|---|---|---|
| hybrid-forced_vs_solo-opus | 8 | 1.33 | [1.0315, 1.7782] | 1.75 | [1.3913, 2.2794] | 0.91 | [0.6726, 1.2789] | 0.00 | 0/10000 |
| hybrid-forced_vs_solo-opus@small | 2 | 1.21 | [1.0802, 1.2331] | 1.64 | [1.2455, 1.7097] | 0.78 | [0.7564, 0.9149] | 0.00 | 0/10000 |
| hybrid-forced_vs_solo-opus@medium | 3 | 1.50 | [0.6581, 1.7067] | 1.98 | [0.8997, 2.2242] | 1.02 | [0.4165, 1.1891] | 0.00 | 0/10000 |
| hybrid-forced_vs_solo-opus@large | 3 | 1.54 | [0.874, 2.5213] | 2.02 | [1.191, 3.264] | 1.06 | [0.5569, 1.7786] | 0.00 | 0/10000 |
| hybrid-inst_vs_solo-opus | 8 | 1.68 | [1.3377, 2.1172] | 2.08 | [1.6703, 2.6609] | 1.17 | [0.9701, 1.3194] | 0.00 | 0/10000 |
| hybrid-inst_vs_solo-opus@small | 2 | 1.66 | [1.6361, 1.9059] | 2.23 | [1.9658, 2.6256] | 1.08 | [1.0831, 1.3064] | 0.00 | 0/10000 |
| hybrid-inst_vs_solo-opus@medium | 3 | 1.32 | [1.1246, 1.3732] | 1.68 | [1.4323, 1.7073] | 0.93 | [0.7527, 1.0557] | 0.00 | 0/10000 |
| hybrid-inst_vs_solo-opus@large | 3 | 1.80 | [1.1929, 2.8419] | 2.21 | [1.4568, 3.6679] | 1.26 | [0.929, 1.4948] | 0.00 | 0/10000 |
| solo-sonnet_vs_solo-opus | 8 | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | -0.15 | 0/10000 |
| solo-sonnet_vs_solo-opus@small | 2 | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | -0.20 | 0/10000 |
| solo-sonnet_vs_solo-opus@medium | 3 | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.00 | 0/10000 |
| solo-sonnet_vs_solo-opus@large | 3 | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | -0.29 | 360/10000 |
<!-- /bench:table -->
**Reading the numbers.**

- The hybrid arms' **Claude side alone** often matched or exceeded the solo run
  (zoekt-1105: `hybrid-forced` $12.09 vs `solo-opus` $4.80 per pass; k6-6169: $26.07 vs
  $12.86). Writing a specification for the executor and verifying its output means the
  conductor still reads the code, and the executor's tokens come on top. agy's 2–10
  minute turnaround per delegation, run one call at a time, is where the wall-clock goes.
- The hybrid won or tied on three tasks (caddy-7888 $1.33 vs $2.02, caddy-7877 $0.79 vs
  $0.73, cli-attach $32.49 vs $37.18 for `hybrid-forced`) and lost clearly on the rest;
  with n = 2–3 per cell those per-task differences are within noise.
- **Judges.** Both judges scored the empty patch 1.0 on every task (floor intact). They do
  **not** rank the author's patch highly (median rank 8 of 12 for both judges), so a judge
  score here measures conformance to the rubric more than agreement with the maintainers;
  inter-judge Spearman 0.43, 55 percent of candidates within one point, point-biserial
  against `pass` 0.37 (Claude judge) and 0.21 (Gemini judge). The Gemini judge compresses
  every arm into 4.3–4.75.
- **Sensitivity.** Without the four runs that slept (see deviations): `hybrid-forced`
  cost-of-pass $10.25 (n = 15), `hybrid-inst` $13.67 (14), `solo-opus` $7.88 (20),
  `solo-sonnet` $4.74 (20) — same ordering, same conclusion.

<!-- bench:table run=full kind=judge -->
| arm | judge | n | mean | consistency | edge_cases | scope | readability | robustness | maintainability |
|---|---|---|---|---|---|---|---|---|---|
| solo-opus | claude | 21 | 4.02 | 4.24 | 4.00 | 3.81 | 4.19 | 4.19 | 3.71 |
| solo-opus | gemini | 21 | 4.74 | 4.76 | 4.62 | 4.71 | 4.95 | 4.62 | 4.76 |
| solo-sonnet | claude | 20 | 3.65 | 3.90 | 3.35 | 3.85 | 3.90 | 3.50 | 3.40 |
| solo-sonnet | gemini | 20 | 4.29 | 4.70 | 3.80 | 4.10 | 4.75 | 4.15 | 4.25 |
| hybrid-forced | claude | 18 | 3.74 | 3.89 | 3.78 | 3.94 | 3.72 | 3.83 | 3.28 |
| hybrid-forced | gemini | 18 | 4.72 | 4.89 | 4.56 | 4.83 | 4.72 | 4.78 | 4.56 |
| author | gemini | 8 | 4.44 | 4.75 | 4.12 | 4.38 | 4.88 | 4.25 | 4.25 |
| author | claude | 8 | 3.79 | 4.12 | 3.88 | 3.50 | 3.75 | 3.88 | 3.62 |
| hybrid-inst | gemini | 16 | 4.75 | 4.81 | 4.56 | 4.56 | 4.88 | 4.94 | 4.75 |
| hybrid-inst | claude | 16 | 3.75 | 3.94 | 3.75 | 3.94 | 3.69 | 3.94 | 3.25 |
| null | gemini | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| null | claude | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

anchors: {"author_rank_by_task": {"claude": {"caddy-7877": "3/10", "caddy-7888": "9/12", "caddy-7913": "8/10", "caddy-7995": "9/13", "cli-14136": "4/13", "cli-attach": "1/10", "k6-6169": "8/11", "zoekt-1105": "9/12"}, "gemini": {"caddy-7877": "2/10", "caddy-7888": "11/12", "caddy-7913": "8/10", "caddy-7995": "6/13", "cli-14136": "11/13", "cli-attach": "2/10", "k6-6169": "7/11", "zoekt-1105": "11/12"}}, "null_max_by_judge": {"claude": 1.0, "gemini": 1.0}, "null_mean_by_judge": {"claude": 1.0, "gemini": 1.0}}; agreement: {"n_candidates_both": 91, "spearman_mean": 0.4349, "within1_pct": 0.549}; judge-vs-pass: {"claude": 0.3688, "gemini": 0.2074}; failed judge calls: 0
<!-- /bench:table -->
**Billing reconciliation.** The project's billing export gives unit prices per SKU over
the run window: Claude Opus 5 $5 / $25 per Mtok with cache write 1.25× and cache read 0.1×
in both context tiers (no long-context premium billed); Claude Sonnet 5 $2 / $10 (Claude
Code's own `costUSD` used these rates; `prices.json`'s 3 / 15 is stale); **Gemini 3.8
Flash $1.50 / $7.50 / $0.15 (input / output / cached), twice the deck's promotional
$0.75 / $3.75 / $0.075**. Totals over the window (other activity on the shared project is
included on the billed side and cannot be separated): Claude Opus computed $458.57 vs
billed $636.07; Claude Sonnet $80.47 vs $137.06; Gemini 3.8 Flash $116.34 at the deck,
$232.68 at the billed rates, vs $277.06 billed; Claude Fable 5.1 $499.50 billed is the
operator's own Claude Code session that ran the study, not part of it. Both cost bases
are therefore shown in every table; the ordering of the arms is the same under either.

**Spend.** $856.82 across all attempts, of which $663.21 in the 75 counted runs, $144.01
in eight attempts interrupted by machine sleep and $49.60 in seven infrastructure
failures (all kept under `runs/*__attempts/`); judging $69.55; smoke and pilot before the
run about $120.

**What this means for the plugin.** The result is the one `docs/POC-PLAYBOOK.md` §0
predicts for repository editing: delegation does not remove the reading and verifying the
conductor must do to own the result, and here it added the executor's tokens and its
latency on top. For per-file delegation on implementation work, use Claude Code directly; the
plugin's saving lives where the digest *is* the deliverable (research, log analysis,
multi-source lookups) and, as the follow-up below measures, where the conductor hands
the whole task over and never reads the code — at a quality cost the follow-up also
measures. Two operational findings from the run belong in the plugin itself: `prices.json`
should carry the Vertex-billed Gemini and Sonnet 5 rates, and agy started in a directory
it has never seen runs in its last project root until `agy --new-project` is issued there.

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
- 22:28Z — k6's `websockets` test package hung for 27 minutes at 11 GB inside the full-suite
  gate of `k6-6169__hybrid-inst__r2` (hidden tests passed) and had failed
  `k6-6169__solo-opus__r1` earlier on one named test. That package imports nothing the k6
  task touches (checked with `go list -deps` at the base commit), so neither failure can be a
  regression from the agent's change. Rule added: a full-suite failure confined to packages
  with no dependency on the changed packages is rerun once whole; if it still fails it is an
  environment failure (`env_failure: suite_failure_in_unrelated_package`) and the item is
  rerun. Applied post hoc to those two runs (reclassified, rerun; the attempts are kept). The
  hanging test `TestLockingUpWithAJustGeneralCancel` is skipped in k6's suite gate from
  22:40Z (`task.json` `verify.skip_notes`). A failure in a package that *does* depend on the
  change remains a failure.
- 2026-09-16 00:39Z — `cli-14136__solo-opus__r3` ended 3.5 minutes after a wake with the
  message "API Error: getaddrinfo ENOTFOUND oauth2.googleapis.com" (Claude Code reports
  `subtype: success`, `is_error: true`), 0 files changed. A run whose final message is an
  API error is now classified `suspended` (after sleep) or `infra` (otherwise) and rerun;
  this one was reclassified post hoc and requeued, together with two other network deaths
  (`cli-attach__hybrid-inst__r1`, `zoekt-1105__hybrid-forced__r1`, both "ENOTFOUND" with 0
  files changed). Two Sonnet runs that had hit the turn cap were swept up by the first
  version of that rule and put back as the capped failures they are (`repairs` in
  `queue.json`); a cap is never treated as infrastructure. Note for the write-up: the
  turn cap binds for `solo-sonnet` (81 turns on a small task with a passing tree).
- 2026-09-16 13:39Z — a 2 h `cli-attach__hybrid-inst__r2` attempt ($24.41) died at a wake
  from a sleep entered on battery (lid closed), like every other run death so far. From
  14:20Z no new item starts while the machine is on battery power (running items are not
  touched); lanes C/D were replaced by E/F to pick the rule up. The waiting time is
  recorded per run (`waited_for_ac_s`).
- 2026-09-16 14:20Z — **stopping rule changed by the operator** at 72 of 96 runs done: the
  laptop must travel and sleeps when closed, and every run death so far came from those
  sleeps. The run stops once every task × arm cell has **n ≥ 2** instead of n = 3. At that
  point 10 cells had n = 3, 20 had n = 2 and 2 had n = 1 (both cli-attach hybrids, the
  2-hour runs most exposed to sleep); only those two cells' second repetitions were still
  run. The 21 skipped items are third repetitions (`status: skipped` in `queue.json`).
  The decision was taken on machine constraints, not on the interim numbers, and the
  pre-registered analysis is unchanged; the tables state n per cell.
- Found after the run (2026-09-17): agy **self-updated the pinned copy of its binary**
  from 1.2.3 to 1.2.4 during the run; 59 runs record agy 1.2.3 and 16 (from 2026-09-16
  04:08Z) record 1.2.4 (`versions.agy` in each `run.json`). The solo arms do not use agy;
  the hybrid arms span both versions. The copy is now read-only (`chmod a-w`). The
  follow-up hand-off arm runs on 1.2.4 throughout.

- 2026-09-17 15:00Z — write attribution corrected after the hand-off run exposed two gaps
  (details in the hand-off log below); every record of this run was re-accounted. Write
  columns of nine records changed (seven `hybrid-inst` shell-write events moved to agy;
  twelve calls across the 75 runs had no `PostToolUse`); costs, passes and exclusions did
  not, and no quoted number moved.

## Follow-up: the hand-off arm (2026-09-16 23:53Z to 2026-09-17 13:26Z)

Pre-registered in `bench/PROTOCOL-handoff.md` (tag `bench/protocol-handoff-v1`) after the
main result, on the token decomposition's prediction that delegation can only save money
if the conductor stops reading. `hybrid-handoff`: Claude Opus 5 with no `Read`, `Glob`,
`Grep`, `Edit` or `Write`, Bash limited to build, vet, test and the wrapper (the gate
blocks file-reading commands), one delegation of the whole requirement to agy
(`--tier flash --timeout 120m`), verification by running the tests, at most one fix-up
delegation. 16 runs (8 tasks × 2) under the main study's caps; the reference arms are the
main run's `solo-opus` and `solo-sonnet` on the same tasks, merged by
`bench.py analyze --run-id handoff --include full:solo-opus,solo-sonnet`.

**Headline.** Handing the whole task to the executor and only verifying **passed 16/16
and cost 0.58× `solo-opus` per passing task** (95% CI 0.39–0.96) at the pre-registered
deck: **0.43× on large tasks** (0.26–0.67), parity on medium (0.99, 0.77–1.11), a loss on
small (1.20, 1.10–2.27). The **Claude side alone was 0.16×** (0.09–0.34): for a user whose
Gemini side is not metered per token, the conductor's bill drops by five sixths. At the
Gemini unit prices this project was billed (twice the deck) the overall ratio is 1.01
(0.69–1.57) and large tasks 0.77 (0.47–1.21): at those rates the saving is confined to
large tasks and its interval includes 1. Wall-clock was 3.6× `solo-opus` (median 40 vs 11
minutes). Against `solo-sonnet` ($4.74 per pass, 17/20) the hand-off arm is equal on total
cost ($4.79) with 16/16 passes and an Opus-verified result; its Claude side is $1.32 per
pass. **The blinded Claude judge, however, rated the hand-off patches 0.61 of 5 below
`solo-opus` (3.42 vs 4.02), past the pre-registered 0.3 margin, on every one of the
eight tasks; the Gemini judge was within the margin (4.52 vs 4.74). By the protocol's
own rule H5 fails and H4 is therefore not claimed**: the arm is cheaper at equal test
outcomes, and it is not quality-neutral.

- **H4 (cost)** — supported at the deck: the overall interval excludes 1 and the point is
  below 0.8; on large tasks alone the interval is 0.26–0.67. Not supported at billed rates
  (1.01).
- **H5 (quality)** — pass rate non-inferior (16/16 vs 21/21); judge means **not**
  non-inferior under the Claude judge (3.42 vs 4.02, margin 0.3; below `solo-opus` on all
  eight tasks, gap 0.55 small / 0.60 medium / 0.67 large) and within the margin under the
  Gemini judge (4.52 vs 4.74; its gap is on large tasks only, 4.44 vs 4.94). H5 fails,
  and with it the protocol withholds H4.
- Mechanism: median 1.5 delegations per run (five runs needed three or four, more than the
  appendix allows); Claude's turns fell to a median of 15.5 (`solo-opus`: 63); agy wrote
  every changed file in every run (no Claude-side write); the conductor's spend is
  verification, not reading.

<!-- bench:table run=handoff kind=arms -->
| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-handoff | 16 | 16/16 | 4.79 | 8.26 | 3.87 (1.55–12.48) | 21.11 | 55.52 / 111.03 | 2382.95 | 15.50 | 1.50 (0) | 6.00 | 2 | 0 |
| solo-opus | 21 | 21/21 | 8.22 | 8.22 | 4.32 (0.65–40.92) | 172.55 | 0.00 / 0.00 | 653.10 | 63 | 0 (21) | 2 | 0 | 0 |
| solo-sonnet | 20 | 17/20 | 4.74 | 4.74 | 2.28 (0.46–8.83) | 80.50 | 0.00 / 0.00 | 676.40 | 69.00 | 0.00 (20) | 3.00 | 0 | 2 |
<!-- /bench:table -->
<!-- bench:table run=handoff kind=size -->
| arm | size | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes | wall med s |
|---|---|---|---|---|---|---|---|
| hybrid-handoff | small | 4 | 4/4 | 2.37 | 3.78 | 2.13 | 968.00 |
| hybrid-handoff | medium | 6 | 6/6 | 4.35 | 7.27 | 4.47 | 2430.10 |
| hybrid-handoff | large | 6 | 6/6 | 6.84 | 12.23 | 7.35 | 4696.80 |
| solo-opus | small | 5 | 5/5 | 1.98 | 1.98 | 2.17 | 399.40 |
| solo-opus | medium | 8 | 8/8 | 4.41 | 4.41 | 4.07 | 576.35 |
| solo-opus | large | 8 | 8/8 | 15.92 | 15.92 | 11.83 | 1487.95 |
| solo-sonnet | small | 5 | 4/5 | 1.98 | 1.98 | 1.32 | 485.10 |
| solo-sonnet | medium | 8 | 8/8 | 1.81 | 1.81 | 2.46 | 630.70 |
| solo-sonnet | large | 7 | 5/7 | 11.62 | 11.62 | 2.73 | 870.90 |
<!-- /bench:table -->
<!-- bench:table run=handoff kind=paired -->
| comparison | tasks | ratio (deck) | 95% CI | ratio (billed rates) | 95% CI | ratio (Claude side only) | 95% CI | pass-rate diff | undefined draws |
|---|---|---|---|---|---|---|---|---|---|
| hybrid-handoff_vs_solo-opus | 8 | 0.58 | [0.3919, 0.9586] | 1.01 | [0.6895, 1.5732] | 0.16 | [0.093, 0.3377] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@small | 2 | 1.20 | [1.0956, 2.2677] | 1.90 | [1.759, 3.5632] | 0.49 | [0.4321, 0.9723] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@medium | 3 | 0.99 | [0.7738, 1.1059] | 1.65 | [1.3091, 1.8562] | 0.32 | [0.2386, 0.3796] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@large | 3 | 0.43 | [0.2577, 0.6746] | 0.77 | [0.4653, 1.2051] | 0.09 | [0.0501, 0.144] | 0.00 | 0/10000 |
| solo-sonnet_vs_solo-opus | 8 | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | -0.15 | 0/10000 |
| solo-sonnet_vs_solo-opus@small | 2 | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | -0.20 | 0/10000 |
| solo-sonnet_vs_solo-opus@medium | 3 | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.00 | 0/10000 |
| solo-sonnet_vs_solo-opus@large | 3 | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | -0.29 | 360/10000 |
<!-- /bench:table -->
<!-- bench:table run=handoff kind=judge -->
| arm | judge | n | mean | consistency | edge_cases | scope | readability | robustness | maintainability |
|---|---|---|---|---|---|---|---|---|---|
| hybrid-handoff | claude | 16 | 3.42 | 3.62 | 3.50 | 3.31 | 3.38 | 3.62 | 3.06 |
| hybrid-handoff | gemini | 16 | 4.52 | 4.75 | 4.12 | 4.38 | 4.75 | 4.56 | 4.56 |
| author | gemini | 8 | 4.56 | 4.62 | 4.62 | 4.12 | 4.88 | 4.50 | 4.62 |
| author | claude | 8 | 3.65 | 3.75 | 3.88 | 3.25 | 3.62 | 3.88 | 3.50 |
| null | gemini | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| null | claude | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| solo-opus | claude | 21 | 4.02 | 4.24 | 4.00 | 3.81 | 4.19 | 4.19 | 3.71 |
| solo-opus | gemini | 21 | 4.74 | 4.76 | 4.62 | 4.71 | 4.95 | 4.62 | 4.76 |
| solo-sonnet | claude | 20 | 3.65 | 3.90 | 3.35 | 3.85 | 3.90 | 3.50 | 3.40 |
| solo-sonnet | gemini | 20 | 4.29 | 4.70 | 3.80 | 4.10 | 4.75 | 4.15 | 4.25 |

anchors: {"author_rank_by_task": {"claude": {"caddy-7877": "6/8", "caddy-7888": "8/10", "caddy-7913": "4/8", "caddy-7995": "2/10", "cli-14136": "9/10", "cli-attach": "1/8", "k6-6169": "5/9", "zoekt-1105": "5/10"}, "gemini": {"caddy-7877": "1/8", "caddy-7888": "2/10", "caddy-7913": "5/8", "caddy-7995": "1/10", "cli-14136": "8/10", "cli-attach": "2/8", "k6-6169": "3/9", "zoekt-1105": "4/10"}}, "null_max_by_judge": {"claude": 1.0, "gemini": 1.0}, "null_mean_by_judge": {"claude": 1.0, "gemini": 1.0}}; agreement: {"n_candidates_both": 73, "spearman_mean": 0.579, "within1_pct": 0.63}; judge-vs-pass: {"claude": 0.3736, "gemini": 0.1886}; failed judge calls: 0
<!-- /bench:table -->

**Reading the numbers.**

- Per task, cost-of-pass `hybrid-handoff` vs `solo-opus` (n = 2 vs 2–3): cli-attach $9.58 vs $37.18,
  k6-6169 $8.68 vs $12.86, caddy-7913 $6.31 vs $8.15, zoekt-1105 $2.25 vs $4.80; and the
  other way on the four cheapest tasks: cli-14136 $4.51 vs $4.30, caddy-7995 $3.09 vs
  $2.82, caddy-7888 $2.24 vs $2.02, caddy-7877 $1.65 vs $0.73.
  The arm wins by a wide margin exactly where the solo run is expensive and loses where
  a solo run costs a dollar or two: the fixed price of one long executor conversation
  plus Claude's verification turns is about $1.5–2.5 per run whatever the task.
- **Where the money goes.** Claude's share of the arm's spend is 28 percent ($21.11 of
  $76.62 at the deck); the rest is one long Gemini conversation per delegation. At the
  billed Gemini rate that Gemini share doubles, which is the whole difference between the
  0.58 and the 1.01.
- **Sensitivity.** Without the five runs that slept mid-run and completed after the
  wake: cost-of-pass $3.75 on 11 runs against `solo-opus` $7.88 on 20 — the same picture.
  Two runs started with a warm cache despite the 300 s gap; kept.
- **Judges.** The empty patch scored 1.0 on every task under both judges (floor intact);
  the author's patch again ranks mid-pack under the Claude judge and near the top under
  the Gemini judge; inter-judge Spearman 0.58, 63 percent of candidates within one point,
  point-biserial against `pass` 0.37 (Claude) and 0.19 (Gemini). The Claude judge's
  rationales for the hand-off patches name the same things on every large task: dead
  code and unused fields, helpers duplicated beside an existing library (a hand-rolled
  CommonMark scanner next to goldmark; a second provisioning client), undocumented extra
  options — the residue of an executor that wrote more than the requirement and a
  conductor that never read the diff. Axis means under the Claude judge, hand-off vs
  `solo-opus`: maintainability 3.06 vs 3.71, readability 3.38 vs 4.19, consistency 3.62
  vs 4.24, scope 3.31 vs 3.81. Against `solo-sonnet` (3.65) and the author's own patch
  (3.65) the hand-off arm is 0.2 lower on the same judge.
- **Spend.** $76.62 in the 16 counted runs ($21.11 Claude, $55.52 Gemini at the deck),
  about $2.6 in four interrupted attempts, $22.70 for judging (64 calls, none failed).
**Caveats.** n = 2 per task and no size class has more than three tasks, so the per-class
intervals are wide; the claim that survives is the overall one at the deck and the
large-task one. Small tasks lose money under this arm as under every delegation arm; at
the deck the break-even sits in the medium class (200–600 changed lines), at the billed
rate above it. Sixteen runs cannot say how often a hand-off fails on a task where the
executor misreads the requirement: here it never did, but five of the sixteen runs
needed a third or fourth delegation to get the tests green, and in the main study 2 of
33 hybrid runs had the executor look the answer up on the web — the executor is not
always right the first time, and the conductor's tests are the only check left — and
the tests do not see dead code or duplication, which is exactly what the Claude judge
docked. No run was excluded, no executor web access was recorded,
and no run hit a cap.

### Deviations log (hand-off run)

- 2026-09-17 04:45Z — Claude Code moves a Bash command that exceeds the tool's timeout to
  the background; the arm's single 120-minute delegation hit the study's 15-minute cap,
  and in a headless session there is no later turn to collect it (`zoekt-1105` r1 ended
  with "I'll pick it up when it completes" and 0 delegations). `hybrid-handoff` now runs
  with a 135-minute Bash timeout; such runs are detected (`bash_cap_backgrounded_delegation`)
  and rerun as environment failures. Four earlier runs (caddy-7913, cli-14136, cli-attach,
  k6-6169, all r1) had a delegation moved to the background but polled it to completion
  and passed; they are kept (their extra polling turns count against the arm).
- 2026-09-17 15:00Z — two gaps in write attribution, found while checking these records,
  fixed in `score.py` and re-applied to every run of both studies (`reaccount`): (1) a
  pipeline such as `printf … | agy-delegate …` has the head `printf`, so its change was
  logged as a Claude shell write (cli-14136 r1, two calls); the gate records every
  segment's head, and the wrapper anywhere in the pipeline now counts as agy; (2) Claude
  Code fires no `PostToolUse` when a tool call returns an error, so a wrapper call that
  exited non-zero after writing (zoekt-1105 r1: five files from one 20-minute delegation)
  left its change unattributed or counted "between calls"; a change first seen at the
  next call is now attributed to the still-open call unless the gate blocked it
  (`post_missing` in the record). Costs, passes and exclusions are unchanged in both
  studies.
- The two lanes ran under launchd (restart after logout or crash) and started no new item
  on battery power; three attempts interrupted by sleep and one by a lane restart are kept
  under `runs/*__attempts/`. Billing reconciliation (window 2026-09-16 20:53Z to
  2026-09-17 16:25Z, refreshed after judging): the Gemini 3.8 Flash SKU unit prices were
  unchanged from the main run ($1.50 / $7.50 / $0.15), which is what the billed-rate
  columns use; $144.07 billed against $111.03 computed at those rates, Claude Opus 5
  $61.78 against $20.25 — the shared project carried other sessions in the window, so
  the gaps are not attributable and the harness totals are the ones used.

## Follow-up 2: hand-off with a self-review pass (2026-09-17 23:21Z to 2026-09-18 10:40Z)

Pre-registered in `bench/PROTOCOL-handoff-review.md` (tag `bench/protocol-handoff-review-v1`)
after the hand-off result: the same arm plus exactly one review delegation to agy in a
fresh conversation once the tests pass, carrying a fixed eight-point checklist written
from the Claude judge's rationales on the hand-off run (dead code, code re-implementing a
dependency, unasked-for options, import grouping, nesting, comments, gofmt, tests), then
verification again and at most one fix-up. The conductor still reads nothing. 16 runs,
same caps; reference arms `solo-opus` and `solo-sonnet` from run `full` and
`hybrid-handoff` from run `handoff`, merged by
`bench.py analyze --run-id handoff-review --include "full:solo-opus,solo-sonnet;handoff:hybrid-handoff" --also-ref hybrid-handoff`.

**Headline.** Adding one self-review delegation by the executor **did not buy the quality
back**: the Claude judge scored the reviewed patches 3.49 against 3.42 for the plain
hand-off (paired per-task difference +0.07, 95% CI −0.12 to +0.22) and 4.02 for
`solo-opus` (−0.54, −0.77 to −0.32, still past the 0.3 margin); the Gemini judge 4.60
against 4.52 and 4.74. Pass rate 15/16; cost-of-pass 0.67× `solo-opus` (0.52–1.02) at
the deck, 0.60× (0.51–0.80) on large tasks, 1.15× the plain hand-off. Both hypotheses
fail — H6 because the reviewer left in place the dead code and the copy-pasted helpers
it was asked to remove, H7 because the interval reaches 1.02. The plain hand-off remains
the cheaper of the two configurations at the same judged quality.

- **H6 (quality recovered)** — not supported: Claude judge 3.49 vs `solo-opus` 4.02 (−0.54, 95% CI
  −0.77 to −0.32; margin 0.3), Gemini judge 4.60 vs 4.74 (−0.10, within). The secondary
  test fails too: against `hybrid-handoff` the paired per-task difference is +0.07 (−0.12
  to +0.22) under the Claude judge and +0.08 (−0.23 to +0.41) under the Gemini judge. Per
  axis the review moved scope +0.25 and maintainability +0.13 (3.06 → 3.19); consistency,
  edge cases and robustness not at all.
- **H7 (cost still lower)** — not supported as pre-registered: cost-of-pass was 0.67×
  `solo-opus` at the deck (below the 0.8 bar) but the 95% CI reaches 1.02. On large tasks
  alone 0.60 (0.51–0.80); small 1.41 (1.05–3.61); medium 0.89 (0.59–1.38). At billed rates
  1.18 (0.93–1.73); Claude side only 0.16 (0.11–0.33). Against `hybrid-handoff` the review
  pass cost 1.15× (0.95–1.38) per passing task, 1.40× (1.18–2.15) on large tasks — half of
  that is the one failed run.
- Pass rate 15/16 (−6 pp against `solo-opus`, inside the 10 pp margin). The failure
  (cli-attach r2) was the implementation, not the review: the executor's changes to the
  `api` structs broke four `TestJSONFields` tests in packages it did not touch, the
  conductor's one fix-up did not cure it, and no review was made because the suite never
  went green. The hidden tests passed.
- Mechanism: the review delegation ran in 15 of 16 runs — median 11 minutes and $1.01 at
  the deck (mean $1.14; about $17 of the arm's $62.51 Gemini spend). No run's suite was
  left red by a review; two runs needed one more delegation after it (a `gofmt` fix, 2
  minutes and $0.13; a review that had exited without doing anything, re-sent, 13 minutes
  and $0.92), one post-review suite failed on a flaky ACME integration test and passed on
  the next run. agy wrote every changed file in every run; median 2.5 delegations per run,
  eight runs with three to six — 12 of the arm's 37 executor calls ended with an error
  status (seven "the stream was interrupted", three network deaths at a sleep, two
  quota 429s), most of them after the work had landed, and the conductor's tests decided
  what happened next.

<!-- bench:table run=handoff-review kind=arms -->
| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hybrid-handoff | 16 | 16/16 | 4.79 | 8.26 | 3.87 (1.55–12.48) | 21.11 | 55.52 / 111.03 | 2382.95 | 15.50 | 1.50 (0) | 6.00 | 2 | 0 |
| hybrid-handoff-review | 16 | 15/16 | 5.51 | 9.67 | 3.67 (2.34–11.48) | 20.07 | 62.51 / 125.03 | 2312.35 | 16.00 | 2.50 (0) | 5.50 | 2 | 0 |
| solo-opus | 21 | 21/21 | 8.22 | 8.22 | 4.32 (0.65–40.92) | 172.55 | 0.00 / 0.00 | 653.10 | 63 | 0 (21) | 2 | 0 | 0 |
| solo-sonnet | 20 | 17/20 | 4.74 | 4.74 | 2.28 (0.46–8.83) | 80.50 | 0.00 / 0.00 | 676.40 | 69.00 | 0.00 (20) | 3.00 | 0 | 2 |
<!-- /bench:table -->
<!-- bench:table run=handoff-review kind=size -->
| arm | size | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes | wall med s |
|---|---|---|---|---|---|---|---|
| hybrid-handoff | small | 4 | 4/4 | 2.37 | 3.78 | 2.13 | 968.00 |
| hybrid-handoff | medium | 6 | 6/6 | 4.35 | 7.27 | 4.47 | 2430.10 |
| hybrid-handoff | large | 6 | 6/6 | 6.84 | 12.23 | 7.35 | 4696.80 |
| hybrid-handoff-review | small | 4 | 4/4 | 2.80 | 4.52 | 2.82 | 1609.20 |
| hybrid-handoff-review | medium | 6 | 6/6 | 3.94 | 6.75 | 4.22 | 2312.35 |
| hybrid-handoff-review | large | 6 | 5/6 | 9.54 | 17.30 | 9.00 | 4352.50 |
| solo-opus | small | 5 | 5/5 | 1.98 | 1.98 | 2.17 | 399.40 |
| solo-opus | medium | 8 | 8/8 | 4.41 | 4.41 | 4.07 | 576.35 |
| solo-opus | large | 8 | 8/8 | 15.92 | 15.92 | 11.83 | 1487.95 |
| solo-sonnet | small | 5 | 4/5 | 1.98 | 1.98 | 1.32 | 485.10 |
| solo-sonnet | medium | 8 | 8/8 | 1.81 | 1.81 | 2.46 | 630.70 |
| solo-sonnet | large | 7 | 5/7 | 11.62 | 11.62 | 2.73 | 870.90 |
<!-- /bench:table -->
<!-- bench:table run=handoff-review kind=paired -->
| comparison | tasks | ratio (deck) | 95% CI | ratio (billed rates) | 95% CI | ratio (Claude side only) | 95% CI | pass-rate diff | undefined draws |
|---|---|---|---|---|---|---|---|---|---|
| hybrid-handoff_vs_solo-opus | 8 | 0.58 | [0.3919, 0.9586] | 1.01 | [0.6895, 1.5732] | 0.16 | [0.093, 0.3377] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@small | 2 | 1.20 | [1.0956, 2.2677] | 1.90 | [1.759, 3.5632] | 0.49 | [0.4321, 0.9723] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@medium | 3 | 0.99 | [0.7738, 1.1059] | 1.65 | [1.3091, 1.8562] | 0.32 | [0.2386, 0.3796] | 0.00 | 0/10000 |
| hybrid-handoff_vs_solo-opus@large | 3 | 0.43 | [0.2577, 0.6746] | 0.77 | [0.4653, 1.2051] | 0.09 | [0.0501, 0.144] | 0.00 | 0/10000 |
| hybrid-handoff-review_vs_solo-opus | 8 | 0.67 | [0.5222, 1.0242] | 1.18 | [0.9347, 1.7282] | 0.16 | [0.1059, 0.3284] | -0.06 | 0/10000 |
| hybrid-handoff-review_vs_solo-opus@small | 2 | 1.41 | [1.054, 3.6064] | 2.28 | [1.6919, 5.8502] | 0.55 | [0.4161, 1.3626] | 0.00 | 0/10000 |
| hybrid-handoff-review_vs_solo-opus@medium | 3 | 0.89 | [0.5855, 1.3837] | 1.53 | [1.0062, 2.3354] | 0.26 | [0.1648, 0.4321] | 0.00 | 0/10000 |
| hybrid-handoff-review_vs_solo-opus@large | 3 | 0.60 | [0.5136, 0.7959] | 1.09 | [0.9404, 1.441] | 0.11 | [0.0819, 0.2078] | -0.17 | 0/10000 |
| hybrid-handoff-review_vs_hybrid-handoff | 8 | 1.15 | [0.9536, 1.3772] | 1.17 | [0.9711, 1.4027] | 1.01 | [0.8494, 1.2326] | -0.06 | 0/10000 |
| hybrid-handoff-review_vs_hybrid-handoff@small | 2 | 1.18 | [0.9621, 1.5903] | 1.20 | [0.9618, 1.6418] | 1.12 | [0.9631, 1.4015] | 0.00 | 0/10000 |
| hybrid-handoff-review_vs_hybrid-handoff@medium | 3 | 0.91 | [0.7567, 1.2512] | 0.93 | [0.7686, 1.2582] | 0.79 | [0.691, 1.2148] | 0.00 | 0/10000 |
| hybrid-handoff-review_vs_hybrid-handoff@large | 3 | 1.40 | [1.1798, 2.1524] | 1.42 | [1.1957, 2.208] | 1.24 | [1.0466, 1.6353] | -0.17 | 0/10000 |
| solo-sonnet_vs_solo-opus | 8 | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | 0.58 | [0.4211, 0.8287] | -0.15 | 0/10000 |
| solo-sonnet_vs_solo-opus@small | 2 | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | 1.00 | [0.8373, 1.1861] | -0.20 | 0/10000 |
| solo-sonnet_vs_solo-opus@medium | 3 | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.41 | [0.254, 0.6196] | 0.00 | 0/10000 |
| solo-sonnet_vs_solo-opus@large | 3 | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | 0.73 | [0.4861, 1.6266] | -0.29 | 360/10000 |
<!-- /bench:table -->
<!-- bench:table run=handoff-review kind=judge -->
| arm | judge | n | mean | consistency | edge_cases | scope | readability | robustness | maintainability |
|---|---|---|---|---|---|---|---|---|---|
| author | gemini | 8 | 4.62 | 4.75 | 4.38 | 4.38 | 4.88 | 4.62 | 4.75 |
| author | claude | 8 | 3.69 | 3.88 | 3.62 | 3.50 | 3.62 | 4.00 | 3.50 |
| hybrid-handoff-review | gemini | 16 | 4.60 | 4.62 | 4.50 | 4.56 | 4.69 | 4.62 | 4.62 |
| hybrid-handoff-review | claude | 16 | 3.49 | 3.62 | 3.50 | 3.56 | 3.44 | 3.62 | 3.19 |
| null | gemini | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| null | claude | 8 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| solo-opus | claude | 21 | 4.02 | 4.24 | 4.00 | 3.81 | 4.19 | 4.19 | 3.71 |
| solo-opus | gemini | 21 | 4.74 | 4.76 | 4.62 | 4.71 | 4.95 | 4.62 | 4.76 |
| solo-sonnet | claude | 20 | 3.65 | 3.90 | 3.35 | 3.85 | 3.90 | 3.50 | 3.40 |
| solo-sonnet | gemini | 20 | 4.29 | 4.70 | 3.80 | 4.10 | 4.75 | 4.15 | 4.25 |
| hybrid-handoff | claude | 16 | 3.42 | 3.62 | 3.50 | 3.31 | 3.38 | 3.62 | 3.06 |
| hybrid-handoff | gemini | 16 | 4.52 | 4.75 | 4.12 | 4.38 | 4.75 | 4.56 | 4.56 |

anchors: {"author_rank_by_task": {"claude": {"caddy-7877": "6/10", "caddy-7888": "1/12", "caddy-7913": "6/10", "caddy-7995": "2/12", "cli-14136": "10/12", "cli-attach": "1/10", "k6-6169": "5/11", "zoekt-1105": "5/12"}, "gemini": {"caddy-7877": "5/10", "caddy-7888": "2/12", "caddy-7913": "6/10", "caddy-7995": "1/12", "cli-14136": "9/12", "cli-attach": "1/10", "k6-6169": "3/11", "zoekt-1105": "1/12"}}, "null_max_by_judge": {"claude": 1.0, "gemini": 1.0}, "null_mean_by_judge": {"claude": 1.0, "gemini": 1.0}}; agreement: {"n_candidates_both": 89, "spearman_mean": 0.502, "within1_pct": 0.584}; judge-vs-pass: {"claude": 0.3625, "gemini": 0.1532}; failed judge calls: 0

paired judge difference (arm − reference; mean of per-task means; task bootstrap 95% CI): hybrid-handoff_vs_solo-opus: claude -0.61 [-0.84, -0.40] (n=8), gemini -0.18 [-0.56, +0.18] (n=8); hybrid-handoff-review_vs_solo-opus: claude -0.54 [-0.77, -0.32] (n=8), gemini -0.10 [-0.54, +0.22] (n=8); solo-sonnet_vs_solo-opus: claude -0.43 [-0.66, -0.21] (n=8), gemini -0.56 [-1.12, -0.04] (n=8); hybrid-handoff-review_vs_hybrid-handoff: claude +0.07 [-0.12, +0.22] (n=8), gemini +0.08 [-0.23, +0.41] (n=8)
<!-- /bench:table -->

**Reading the numbers.**

- Per task, cost-of-pass review arm / `hybrid-handoff` / `solo-opus`: cli-attach $20.62
  (one pass of two) / $9.58 / $37.18, k6-6169 $10.24 / $8.68 / $12.86, caddy-7913 $4.77 /
  $6.31 / $8.15, zoekt-1105 $3.31 / $2.25 / $4.80, cli-14136 $4.26 / $4.51 / $4.30,
  caddy-7995 $2.97 / $3.09 / $2.82, caddy-7888 $2.80 / $2.24 / $2.02, caddy-7877 $2.63 /
  $1.65 / $0.73. The review pass is a fixed dollar per run, so it hurts exactly where the
  hand-off already lost (small tasks) and is noise on the large ones; the arm's total in
  counted runs, $82.59, is $6 above the hand-off's $76.62 because the implementation
  delegations happened to come in cheaper this time.
- **Judges.** Floor intact (the empty patch scored 1.0 under both judges); the author's
  patch ranks first on two tasks and mid-pack elsewhere; inter-judge Spearman 0.50, 58
  percent of candidates within one point; point-biserial against `pass` 0.36 (Claude) and
  0.15 (Gemini). The Claude judge's rationales for the *reviewed* cli-attach patches name
  the same residue as before the review — `isSingleImage`, `UploadStub`, an unused
  `*testing.T` parameter, a 600–700-line hand-rolled byte scanner beside goldmark, upload
  plumbing copy-pasted across five or six commands — which is what the checklist asked
  the reviewer to remove. A Flash reviewer reading its own work with that checklist
  recognises little of it as a problem; its summaries report import fixes, a removed
  helper or two, comments. Per size class under the Claude judge (review / hand-off /
  `solo-opus`): small 4.17 / 3.92 / 4.47, medium 3.61 / 3.50 / 4.10, large 2.92 / 3.00 /
  3.67.
- **Sensitivity.** Without the four runs that slept mid-run and completed: cost-of-pass
  $4.98 on 12 runs (`hybrid-handoff` $3.75 on 11, `solo-opus` $7.88 on 20). Wall-clock
  median 38.5 minutes, the same as the hand-off arm's 39.7 (the review runs while the
  conductor waits; it replaced turns the hand-off arm spent polling).
- **Spend.** $82.59 in the 16 counted runs ($20.07 Claude, $62.51 Gemini at the deck),
  $12.63 in two attempts that died of a sleep, $22.24 (64 calls, none failed) for judging.

**Caveats.** Same n = 2 per task and the same wide per-class intervals as the hand-off
run. The reviewer is the model that wrote the code, given a checklist derived from one
judge's complaints about that code: it acted on little of that checklist, and a different reviewer — the conductor
reading the diff once and handing a list back, the option not chosen for this run —
remains unmeasured. The permission matcher denied a
median of 5.5 wrapper calls per run (multi-line single-quoted arguments; the conductor
found a form that matched after a few tries, as in the hand-off arm) — turns the arm
pays for that a shipped command would not.

### Deviations log (hand-off-review run)

- 2026-09-17 23:21Z — the queue was built without `allow_same_arm_concurrency`, so lane
  B idled for 11 minutes at the start; set by hand at 23:32Z. No effect on results.
- 2026-09-18 05:07Z — cli-attach r1 slept 67 minutes mid-run; both of its delegations
  came back with network errors after 126 and 22 minutes, and the run failed with nothing
  delivered ($10.95). The classifier of the time called it `final`; under the
  pre-registered sleep rule it is a rerun, so it was relabelled `suspended` and requeued,
  and `classify()` now treats a slept, delegating run with no successful delegation and no
  pass as `suspended`. The rerun passed.
- 2026-09-18 10:41Z — the operator started judging the seven finished tasks by hand while
  the post-run agent was already judging them; the duplicate loop was stopped six minutes
  later. Both wrote identical-form records for the first task; the agent's later ones
  overwrote the earlier ones. No effect on scores.
- Judging and analysis ran under the `postrun` launchd agent (waits for the queue, judges
  on mains power only, retries a record left by a killed call, analyzes, exits). The
  laptop slept on battery from about 11:10Z to 15:27Z with the fourth task half judged;
  the one call that died in the sleep ("empty response") was re-judged after the agent
  had moved on, and the aggregate was regenerated with it. Billing reconciliation (window
  2026-09-17 20:32Z to 2026-09-18 13:39Z): Gemini 3.8 Flash $198.41 billed against
  $125.03 computed at billed rates, Claude Opus 5 $80.70 against $20.04 — the shared
  project carried other sessions in the window; the per-SKU unit prices were unchanged ($1.50 / $7.50 / $0.15 per Mtok).

## Versions and provenance

Claude Code 2.1.272 (pinned binary) and Go 1.27.1 in both runs; plugin 0.28.0 (`5392467`)
for the hybrid arms; agy 1.2.3 → 1.2.4 during the main run, 1.2.4 → 1.2.5 during the
hand-off run and 1.2.5 (7 runs) and 1.2.6 (9 runs) during the hand-off-review run — the CLI updates itself even from a
read-only binary, and each `run.json` records the version it saw. Prices frozen in `bench/prices.lock.json`. The pilot ran on
Claude Code 2.1.270 and agy 1.2.2.

## What is not counted

Gemini context-cache storage (not reported by agy, so the Gemini side is a lower bound);
harness overhead (checkout, scoring); human time spent writing prompts; the cost of the
judging pass (reported separately).
