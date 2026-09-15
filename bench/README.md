# bench/ — real-PR replay benchmark

Measures whether "Claude Code + this plugin (implementation delegated to agy / Gemini)"
costs less than "Claude Code alone" on realistic feature work **without losing quality**.
The write-up with numbers lives in `docs/BENCHMARK.md`; the pre-registered protocol in
`PROTOCOL.md`. This file says how the machinery works and how to run it. It contains no
results on purpose.

## What is measured

* **Tasks** are merged pull requests from public Go repositories, merged after
  2026-07-01 (after the models' training cutoffs). A task is the repository at the PR's
  parent commit plus the PR's test files; the requirement is a 20–30 line prompt written
  from the PR description without naming files or identifiers the author introduced
  (`bench.py curate lint` checks). Tasks are replayable: `tasks/<owner>__<repo>/<id>/`.
* **Arms** (`arms.json`) share one task prompt, one verification-only Bash policy
  (`policy/`, enforced by `hooks/bash-gate.py` in every arm), the same caps per size
  class, and differ only in: plugin loaded or not (`--plugin-dir`), whether Edit/Write
  are available (`hybrid-forced` has neither), the prompt appendix (`prompts/`), and the
  conductor model (`solo-sonnet`).
* **Outcome** = the PR's test files are restored over whatever the agent left (blob-hash
  tamper check first), then `go build`, `go vet`, the hidden tests, the full suite,
  `gofmt -l`. `pass` needs all five.
* **Cost** = Claude Code's own list-price `modelUsage.costUSD` (recomputed from tokens
  against `prices.lock.json` and cross-checked) plus the Gemini side priced from the
  wrapper's `AGY_USAGE_LOG` as `input×in + output×out + cache_read×cached` per line
  (the invariant `input + output == total` is asserted per line). Both sides are
  pay-as-you-go on one GCP project here, so the totals are reconciled against the
  billing export per quiet run window.
* **Attribution**: `hooks/tree-trace.sh` fingerprints the working tree before and after
  every Bash/Edit/Write call, so each change is attributed to a Claude file tool, a Claude
  shell command, or an `agy-delegate` call. A hybrid run in which Claude wrote the code
  is visible as such; `hybrid-forced` structurally cannot.
* **Quality review**: blinded, single-candidate, two judge families, with the author's
  patch and an empty patch mixed in unlabelled (`harness/judge.py`).

## Layout

```
arms.json  prices.lock.json  PROTOCOL.md
prompts/   task-template.md, hybrid-appendix.md, hybrid-forced-appendix.md, judge.md
policy/    allow-common.txt, allow-plugin.txt, bash-gate-rules.json
config/    settings.template.json   (rendered per run into an isolated CLAUDE_CONFIG_DIR)
hooks/     bash-gate.py, tree-trace.sh
harness/   common.py gates.py curate.py run.py score.py claude_usage.py agy_usage.py judge.py analyze.py
tasks/     <owner>__<repo>/repo.json, <task-id>/{task.json,prompt.md,tests.list,hidden/,author.patch}
results/   <run-id>/runs/<task>__<arm>__r<n>/{run.json,patch.diff,raw/}   (raw/ is git-ignored)
tests/     unittest suite; every test names the mutation it catches
```

Scratch lives under `~/.cache/agy-bench/` (`AGY_BENCH_HOME`): git mirrors, per-run
checkouts and config dirs, shared `GOMODCACHE`/`GOCACHE`.

## Running

```bash
# 1. curate a task from a merged PR (or a stack: --prs 14177-14184)
python3 bench/bench.py curate mirror caddyserver/caddy
python3 bench/bench.py curate make caddyserver/caddy --prs 7913 --task-id caddy-7913
#    write tasks/caddyserver__caddy/caddy-7913/prompt.md by hand from prompt.draft.md
python3 bench/bench.py curate lint caddy-7913        # no leaked identifiers or paths
python3 bench/bench.py curate prewarm caddy-7913     # module + build caches, base and target
python3 bench/bench.py curate verify caddy-7913      # fails at base, 3x green at target

# 2. one run (a clean checkout of the plugin at a pinned SHA for the hybrid arms)
python3 bench/bench.py run --run-id pilot --task caddy-7913 --arm solo-opus --rep 1
python3 bench/bench.py run --run-id pilot --task caddy-7913 --arm hybrid-forced --rep 1 \
    --plugin-dir ~/.cache/agy-bench/plugin

# 3. ask the policy about a command; stop a run
python3 bench/bench.py gate "go test ./... 2>&1 | tail -20"
python3 bench/bench.py stop --run-id pilot
```

Requirements: Claude Code ≥ 2.1.270 configured for Vertex in `~/.claude/settings.json`
(only the Vertex/model `env` keys are copied into the isolated config), `agy` signed in,
`gh` authenticated (curation only), Go, python3. No docker.

## Self-tests

```bash
python3 -m unittest discover -s bench/tests -t bench
```

The suite is also run by `tests/run-tests.sh`. Each test's docstring names the mutation it
catches; before adding an assertion, break the code and watch it fail.
