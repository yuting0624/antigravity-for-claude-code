# Changelog

All notable changes to **Antigravity for Claude Code**. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions are in `.claude-plugin/plugin.json`.

## 0.15.0
- **New command — `/antigravity:cloud-run-debug`** (Conductor/Executor demo): diagnose a failing
  Cloud Run service. agy (Gemini) does the bulk, cheap work — pulling `severity>=ERROR` logs via
  `gcloud logging read` and clustering them into a structured digest (error clusters /
  representative stack traces / time distribution / likely root-cause candidates) — and Claude
  ingests only that digest to infer the root cause and propose a fix. The lean handoff keeps
  Claude's context (and cost) down.
  - **Read-only by default** — diagnosis + proposal only. `--apply` is the only write path, and it
    only ever lands the fix on a dedicated branch with the diff shown for a human to review/merge;
    nothing is deployed or merged automatically.
  - **Narrow surface, generic engine:** one user-facing command, but the engine
    (`scripts/cloud-debug.sh`, shimmed as `bin/cloud-debug`) takes `--resource-type` (default
    `cloud_run_revision`) so a future gke-/functions-debug can reuse it without a rewrite. The
    digest reuses `agy-delegate.sh` — no new delegation logic.
  - **Safety:** uses the existing `gcloud` ADC (never asks for tokens); a missing
    `roles/logging.viewer` exits with the exact `add-iam-policy-binding` fix.
  - **Lean by construction:** the log payload handed to agy is field-projected
    (`--format='json(timestamp,severity,textPayload,jsonPayload,httpRequest.status)'`,
    dropping resource/insertId noise ~5-10x) and byte-capped before the handoff
    (`CLOUD_DEBUG_MAX_BYTES`, default 200000; the tail is clipped and agy is told
    the digest may be partial) — so the "cheap / lean handoff" claim holds even on
    noisy services where `--limit` alone bounds entry *count* but not byte volume.
  - `doctor` checks the new script/shim; `tests/` stub `gcloud` + `agy` and cover the
    fetch→digest, default `--since`, read-only (no writes / no `--apply` in the engine), and
    permission-denied paths.

## 0.14.0
- **`bin/` entrypoints — fixes `$CLAUDE_PLUGIN_ROOT` failures on marketplace installs**
  ([#11](https://github.com/yuting0624/antigravity-for-claude-code/issues/11)):
  `$CLAUDE_PLUGIN_ROOT` is only substituted in structured config (hooks/MCP/LSP) and is
  **not** exported to model-run Bash — so commands/skills that ran
  `"$CLAUDE_PLUGIN_ROOT/scripts/…"` expanded to an empty path and failed. Scripts are now
  invoked by **bare name via `bin/` shims** (Claude Code adds a plugin's `bin/` to the
  Bash-tool PATH): `agy-delegate` / `agy-job` / `agy-cost-compare` / `agy-doctor`. Commands,
  the skill, and the delegate subagent were updated; the PreToolUse gate accepts the bin
  names; `doctor` checks the shims. (`scripts/` is unchanged — the shims forward to it.)
- **Write-delegation guidance + guard**
  ([#10](https://github.com/yuting0624/antigravity-for-claude-code/issues/10)): without
  `--yolo`, headless agy only *describes* edits and returns a confident success **while
  writing no files**. The `delegate` command now makes `--yolo` explicit for write tasks
  (on a branch), notes the harness may prompt for / block `--dangerously-skip-permissions`,
  and flags the ~2-min sync Bash limit (→ background job). `agy-delegate.sh` now warns when a
  write-looking prompt lacks `--yolo`. (The verification gate already caught the no-write.)
- Thanks to **@erszcz** (#10) and **@Masterisk-F** (#11) for the reports.

## 0.13.0
- **Windows headless hang fixed / diagnosed** ([#6](https://github.com/yuting0624/antigravity-for-claude-code/issues/6)):
  on native Windows without a console (ConPTY), headless `agy -p` / `agy models` could
  hard-hang with a 0-byte log when stdio is redirected.
  - **`agy-delegate.sh`**: wraps agy in a wall-clock guard (GNU `timeout`/`gtimeout`,
    with `--kill-after`) sized from `--timeout` + head-room, so a hang now returns a
    structured **TIMEOUT (exit 12)** + `AGY_SIGNAL` instead of blocking forever. Warns on
    native Windows when no `timeout` binary is available.
  - **`doctor.sh`**: `agy models` (and the version probe) are now time-bounded and **distinguish a hang from an
    auth failure** — it no longer tells you to re-authenticate when agy is actually hung
    headless (the misdiagnosis that cost the reporter hours). A genuine empty result still
    reports "not authenticated".
  - **README**: added a Platform-support note (macOS/Linux/WSL supported; native Windows
    not recommended for headless delegation) and a known-limit entry.
  - **tests**: added a hang → wall-clock-guard → exit 12 case (skips cleanly without `timeout`).
  - Thanks to **@rokushikii** for the detailed, reproducible report.

## 0.12.0
- **Configurable executor model** (agy is multi-model): tiers still default to Gemini, but
  each is remappable to any `agy models` entry (Claude/GPT on plans that expose them) via
  `tier_flash` / `tier_flash_lo` / `tier_pro`, plus a `default_model` (exact name) option —
  all `CLAUDE_PLUGIN_OPTION_*`. Precedence: `--model` > explicit `--tier` > `default_model`
  > default tier. Keeps Gemini as the recommended default (a different/cheaper executor is
  what yields the cost + cross-model-verification benefit).
- **doctor**: tier-model check now respects the remaps and **warns instead of failing** when a
  model isn't in `agy models` (agy is plan-dependent), with a remap hint.
- (Reported via Reddit: agy supports Claude/GPT on non-Vertex plans.)

## 0.11.1
- **WSL slow-mount guard**: `agy-delegate.sh` warns when `--add-dir` targets a Windows
  mount (`/mnt/*`) under WSL — agy reads it over a slow 9p bridge, so even trivial calls
  can take 20s+ — and `doctor` flags a workspace on `/mnt/*`. Fix: keep the repo on the
  WSL Linux filesystem (`~`). Also documented in known-limits. (Reported via Reddit.)

## 0.11.0
- **Auto-injected routing policy** (`hooks/`): a `SessionStart` hook injects the
  plugin's **cost-aware** routing policy as session context (delegate above the
  break-even, keep Claude's context lean, always verify) so the discipline applies
  without invoking the skill. Toggle via the `coding_policy` plugin option. A second
  hook does a fast `agy` presence/auth check on session start.
- **Delegation subagent** (`agents/antigravity-delegate.md`): `tools: Bash, Read, Glob`
  with a `PreToolUse` gate (`hooks/validate-delegate-bash.sh`) that permits only the
  delegation wrapper — no `Write`/`Edit`, no arbitrary Bash — so file *writing* runs on
  agy/Gemini (no Claude tokens spent generating file contents); it returns a digest for
  Claude to verify.
- **Structured exit codes + signal**: `agy-delegate.sh` now classifies failures into
  `10` quota · `11` auth · `12` timeout · `13` agy-missing and prints a machine-readable
  `AGY_SIGNAL {...}` line; `agy-job.sh` surfaces the code/label/signal in `status`/`result`.
- **Plugin options** (`userConfig`): `default_tier`, `timeout`, `coding_policy` — read by
  the wrapper/hook via `CLAUDE_PLUGIN_OPTION_*` (explicit flags still override).
- **`/antigravity:research`** command: surfaces the skill's Claude-orchestrated deep-research
  recipe — agy fans out grounded web search (compact digests), Claude verifies each
  load-bearing claim across ≥2 independent sources and synthesizes a cited report.
- **`--print-command`** (agy-delegate dry run): prints the resolved `agy …` invocation
  without executing — for debugging/trust; works even without agy installed.
- **Plugin-contract test**: asserts the manifests, that every hook/agent file reference
  resolves, command/skill/agent frontmatter is present, and hook scripts are executable —
  catches a broken reference before release.
- **CI**: shellcheck + JSON validation now also cover `hooks/`.

## 0.10.0
- **Pricing config** (`prices.json`): single source of current Vertex rates (Opus 4.8
  5/25, Sonnet 4.6 3/15, Gemini 3.5 Flash 1.50/9, Gemini 3.1 Pro 2/12). `measure-session.py`
  now prints an estimated **USD** figure; `agy-cost-compare.sh` defaults come from it
  (env still overrides; Gemini rate picked by tier).
- **doctor**: validates each tier→model name still exists in `agy models` (guards against
  agy renaming models across versions).
- **CHANGELOG.md** added.
- **CI** (GitHub Actions): shellcheck + dependency-free test suite + JSON manifest
  validation on every push/PR.

## 0.9.0
- **Background jobs** (`scripts/agy-job.sh`, codex-style): `start`/`list`/`status`/
  `result`/`cancel`, daemonized worker + per-job registry. Slash commands
  `/antigravity:status|result|cancel`. For interactive sessions; headless stays synchronous.

## 0.8.0
- **Code-review fixes**: mktemp+trap for stderr (was a fixed `/tmp` path = concurrency
  race); friendly arg validation; content-anchored `usage()`; `--yolo` passthrough +
  div-by-zero guard in cost-compare; `with open` + scope caveat + multi-match warning in
  measure-session.
- **Slash commands** `/antigravity:delegate|review|setup`; `scripts/doctor.sh`;
  dependency-free `tests/run-tests.sh`.

## 0.7.x
- Repackaged for public release: sanitized internal identifiers, genericized references,
  MIT `LICENSE`, disclaimer.

## 0.4.0–0.6.0
- Deep-research recipe; verification gates incl. agy tamper-detection; cost-discipline
  section (break-even, lean context, digest, cache-TTL trap); `measure-session.py`;
  `docs/AB-RESULTS.md` (measured A/B) and `docs/DEMO-KIT.md`.

## 0.1.0–0.3.0
- Initial plugin: `agy-delegate.sh` wrapper, `antigravity` skill (SDLC model routing,
  conductor/orchestrator), `agy-cost-compare.sh`, marketplace + plugin manifests.
