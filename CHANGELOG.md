# Changelog

All notable changes to **Antigravity for Claude Code**. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions are in `.claude-plugin/plugin.json`.

## 0.18.4
- **`bin/measure-session` shim** — `measure-session.py` was the only script without a `bin/`
  entrypoint, so it couldn't be run by bare name from a marketplace install (only via the
  `scripts/` path, which doesn't resolve from a user's own repo). It now has a shim like the
  others, so `measure-session <session-id>` works on the PATH. (`doctor` + contract tests
  cover it.)

## 0.18.3
- **`doctor` fix — recognize tier models across `agy models` format changes.** agy 1.1.5
  switched `agy models` output from **display names** (`Gemini 3.5 Flash (High)`) to
  **slugs** (`gemini-3.5-flash`), which broke doctor's strict `grep` and made it **falsely
  warn that every tier model was missing** (they still work). doctor now normalizes both
  sides (lowercase-alphanumeric, bidirectional substring), so it survives either format.
- **Verified against agy 1.1.4 / 1.1.5.** Default `flash` delegation, tier resolution, and
  exit-code classification all work on 1.1.5 (1.1.4/1.1.5 were mostly interactive/UX:
  `--effort`, stable model slugs, `/model` picker, MCP fixes).
- **Gemini 3.6 Flash** now appears in `agy models` and **works** (verified all effort
  variants through the wrapper). The `flash` **default stays Gemini 3.5 Flash (High)** for
  broad plan availability (newer models can lag on enterprise Vertex) — remap `tier_flash`
  to `Gemini 3.6 Flash (High)` if your plan serves it. (Both display names and 1.1.5 slugs
  are accepted by `--model`.)
- **Still unchanged upstream** (re-confirmed on 1.1.5): headless writes need `--yolo` (a
  `permissions.allow` write-rule was still soft-denied in testing despite 1.1.4's
  "honor settings.json headless"), `--output-format json` not externally available yet,
  native Windows headless (`#508`/`#6`) unresolved.

## 0.18.2
- **agy 1.1.3: headless write model changed again — `--yolo` is now the durable grant.**
  All verified live on 1.1.3:
  - 1.1.3 **removes the scratch-divert**: a write/tool needing permission is now
    **soft-denied** in headless mode with a clear stderr notice (rc=0 + empty stdout).
    This is the upstream's intended behavior (announced), not a bug — the evolved issue #10.
  - **`--mode accept-edits` no longer grants headless writes** (soft-denied for create AND
    edit on 1.1.3 — it had been riding the auto-approve behavior that 1.1.3 closed). Docs,
    the `delegate` command, and the write-task warning now point to **`--yolo`** as the
    reliable headless write/tool grant across versions; `--mode` passthrough stays but is
    no longer recommended for writes.
  - **New structured failure `15` — permission denied**: the wrapper detects the soft-deny
    stderr (rc=0 + empty) and returns exit `15` + `AGY_SIGNAL {PERMISSION_DENIED}` with an
    actionable message ("add `--yolo`"), instead of a bare "empty output". `agy-job`
    renders it.
  - Note: `--output-format json` is **still not externally available**, and native Windows
    headless (`#508`/`#6`) is **still unresolved** — WSL guidance and plain-text parsing stay.

## 0.18.1
- **New structured failure `14` — model unavailable** (agy 1.1.2): agy now **hard-fails**
  (instead of silently downgrading to the default model) when `--model` can't be resolved.
  The wrapper classifies this into exit `14` + `AGY_SIGNAL {MODEL_UNAVAILABLE}` and prints
  an actionable hint (run `agy models`; fix `--model` / `tier_*` / `default_model`) — the
  common failure when a tier remap points at a model your plan doesn't expose. `agy-job`
  renders the new code.
- **Note on agy 1.1.x upstream fixes** (verified against release notes): 1.1.1 fixed
  `agy -p` hanging inside a subprocess/script and print mode silently exiting success on a
  server-side error; both are now non-zero + stderr, so the wrapper classifies them
  correctly. Native Windows headless (`#508`/`#6`) is **still not resolved upstream**, and
  `--output-format json` is **still not externally available** — the WSL guidance and
  plain-text parsing stay.

## 0.18.0
- **agy 1.1.0 support — `--mode accept-edits|plan` passthrough** (all behaviors below
  verified live on 1.1.0):
  - 1.1.0 makes **review-first** the default execution mode. Headless consequence
    (measured): a write task **without** write permission no longer just "describes" —
    agy writes the files to its **own scratch dir** (`~/.gemini/antigravity-cli/scratch`)
    and reports success, while your workspace stays untouched (the evolved #10 failure
    mode).
  - New wrapper flag **`--mode accept-edits`**: auto-applies FILE EDITS to the real
    workspace *without* granting terminal/tool permissions — a **narrower grant than
    `--yolo`**, now the recommended way to run pure write delegations. `--yolo` remains
    for tasks that also need tools (web / Vertex AI Search / terminal); verified
    backward-compatible on 1.1.0. `--mode plan` passes through for strategize-only runs.
  - The write-task warning now fires only when *neither* `--mode accept-edits` nor
    `--yolo` is set, and explains the scratch-divert behavior.
  - Subagents re-verified on 1.1.0 (`define_subagent` → `invoke_subagent`, transcript
    path unchanged); they are **officially documented** as of 1.1.0, with static config
    at `<workspace>/.agents/agents/*.md` and global `~/.gemini/config/agents/` — the
    skill's fan-out recipe now points at the official docs.
  - `delegate` command, skill safety section, and README write guidance updated to the
    "prefer `--mode accept-edits`, escalate to `--yolo` only for tools" split.

## 0.17.0
- **Frictionless delegation — no slash command required, judgment stays with Claude.**
  Two additions reduce the "you must type `/antigravity:delegate` every time" friction,
  while deliberately NOT auto-routing (full automation below the break-even is a
  measured net loss):
  - **Proactive subagent selection**: the `antigravity-delegate` description now tells
    Claude to use it *proactively* for bulk work (scaffolding / exhaustive tests /
    migrations / fan-out search) — with the explicit counterweight that the break-even
    judgment is Claude's, every time.
  - **Prompt-level nudge** (`hooks/nudge-delegation.sh`, UserPromptSubmit): a cheap,
    deterministic heuristic (volume/fan-out phrases, EN + JA) adds a short advisory note
    when a prompt looks above the break-even. Advisory material only — the note itself
    says "THE JUDGMENT IS YOURS". Only the `prompt` field is scanned (no cwd/path false
    positives), the user's prompt is never echoed back (no injection surface), and it
    stays silent when the user is already delegating. Toggle via the new
    `delegation_nudge` plugin option.

## 0.16.1
- **Internal fan-out recipe updated for agy 1.0.16** (re-verified per the recipe's own
  "re-verify after upgrades" caveat — which became real within a day): **dynamic custom
  subagents now work** — `define_subagent` a named specialist in-session, then
  `invoke_subagent` it by TypeName (1.0.13–1.0.15 shipped this broken, upstream #521;
  fixed in 1.0.16 via the JSON→Markdown definition change). The `self`+Role pattern
  stays as the any-version fallback (re-verified on 1.0.16). `transcript.jsonl`
  location is unchanged across 1.0.12→1.0.16, so `agy-trace` is unaffected. The recipe
  now flags the whole surface as fast-moving (4 upstream releases in a week; official
  static agent-config docs drift from behavior, upstream #527).

## 0.16.0
- **Internal fan-out recipe + `agy-trace`** (community pointer to upstream
  antigravity-cli#105; **verified headless on agy 1.0.12**): agy's `invoke_subagent`
  sandbox only allows TypeNames `self`/`research` — custom TypeNames are rejected. The
  skill now documents the **role-delegation pattern** (TypeName `self` + a specialist
  `Role`) for one-delegation internal fan-out, so coordination tokens land on the cheap
  (Gemini) side instead of the frontier side. Spawning needs no `--yolo` (writes inside
  the work still do).
  - Each spawned subagent leaves a **readable step-by-step `transcript.jsonl`** under
    `~/.gemini/antigravity-cli/brain/<conversationId>/` — unlike the opaque conversation
    `.db` blobs. New **`agy-trace`** (script + bin shim) pretty-prints one (`agy-trace
    <conversationId>`), lists recent ones (`--list`), or emits raw JSONL (`--raw`) so
    Claude can run a real trajectory audit on what subagents actually did.
  - Skill's trajectory-check gate updated accordingly; `doctor` covers the new script/shim.
- **`--digest` flag + digest-size guard** — the cost discipline's biggest lever ("ingest
  digests, not dumps") is now enforced in code, not just prose
  ([#5](https://github.com/yuting0624/antigravity-for-claude-code/issues/5)):
  - `agy-delegate --digest` appends a digest-only **output contract** to the prompt
    (compact bullets + a one-line `DIGEST:` trailer; no full files / raw logs).
  - The wrapper now **warns on stderr when a reply comes back dump-sized** (default
    threshold 8000 chars) so the conductor doesn't silently ingest a raw dump. New plugin
    option `digest_warn_chars` tunes it (`0` disables).
  - `delegate` command + skill updated to use `--digest` for bulk reads and to not ingest
    a flagged dump.
- **Support docs — one-round-trip diagnosis**: every environment bug so far (#6, #10,
  #11, #15) needed the same three facts, so they're now asked up front:
  - **Issue templates** (`.github/ISSUE_TEMPLATE/`): the bug form requires `agy-doctor`
    output, OS/platform, and install method (marketplace vs `--plugin-dir`).
  - **`docs/TROUBLESHOOTING.md`**: symptom-first fixes — Windows headless hang (and the
    "agy works when I type it" console explanation), WSL `/mnt` slowness, silent
    no-write without `--yolo`, exit-code/`AGY_SIGNAL` table, tier remaps, updating.

## 0.15.1
- **Injected routing policy no longer references `$CLAUDE_PLUGIN_ROOT`**
  ([#15](https://github.com/yuting0624/antigravity-for-claude-code/issues/15), fix by
  **@Masterisk-F** in #16): the SessionStart `additionalContext` in
  `hooks/policy-context.json` still told the model to run
  `"$CLAUDE_PLUGIN_ROOT/scripts/agy-delegate.sh"` — but that variable isn't exported to
  model-run Bash (same root cause as #11), so it expanded empty and the model had to
  rediscover the `bin/` entrypoint. Now uses the bare `agy-delegate` bin name. (The #11
  bin/ migration updated commands/skill/agents but missed this injected string.)
  - This ships as a **version bump** so `/plugin marketplace update` recognizes the fix —
    #16 landed on `master` without one, leaving installs on 0.15.0 unable to see it.
- **Regression guard widened**: the contract test now also fails if any SessionStart
  `additionalContext` references `$CLAUDE_PLUGIN_ROOT` (not just commands/skill markdown),
  so this class of bug can't recur in injected context.
- **Version-drift guard**: the contract test now asserts `SKILL.md`'s `version:` matches
  `plugin.json` — they had drifted (skill stuck at 0.14.0 while the plugin was 0.15.0);
  re-synced to 0.15.1.

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
  - **`--apply` dirty-tree guard + project visibility:** before branching, `--apply` checks
    `git status --short` and stops if the tree is dirty (so a user's uncommitted changes can't
    leak into the fix's diff/commit); and `--project` is now a surfaced flag, with the command
    confirming the resolved project when it isn't passed (avoids reading the wrong GCP project).
  - **Lean by construction:** the log payload handed to agy is field-projected
    (`--format='json(timestamp,severity,textPayload,jsonPayload,httpRequest.status)'`,
    dropping resource/insertId noise ~5-10x) and byte-capped before the handoff
    (`CLOUD_DEBUG_MAX_BYTES`, default 200000; the tail is clipped — byte-accurate
    across locales, so multibyte logs are bounded too — and agy is told the clipped
    JSON is partial/invalid) — so the "cheap / lean handoff" claim holds even on
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
