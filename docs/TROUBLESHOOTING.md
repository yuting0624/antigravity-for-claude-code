# Troubleshooting

Symptom-first guide to every problem reported so far. **Start by running `agy-doctor`**
(or `/antigravity:setup` inside Claude Code) — it diagnoses most of the below and prints
the plugin version, agy version/auth state, and platform warnings.

---

## "`/scripts/agy-delegate.sh: No such file or directory`" or `$CLAUDE_PLUGIN_ROOT` is empty

**Cause:** you're on a plugin version < 0.14.0. `$CLAUDE_PLUGIN_ROOT` is only substituted
inside structured config (hooks/MCP) — it is **not** exported to the shell commands the
model runs, so marketplace installs saw an empty path ([#11](https://github.com/yuting0624/antigravity-for-claude-code/issues/11),
[#15](https://github.com/yuting0624/antigravity-for-claude-code/issues/15)).

**Fix:** update — since 0.14.0 everything is invoked by bare names (`agy-delegate`,
`agy-job`, `agy-doctor`, `agy-cost-compare`) on the plugin's `bin/` PATH:

```
/plugin marketplace update antigravity-for-claude-code
/reload-plugins
```

---

## Windows: delegation hangs, or exits 12 (TIMEOUT) with a 0-byte log

**Cause (upstream, not the plugin):** on native Windows, headless `agy` needs a real
console (ConPTY). When the plugin runs it as a child process with redirected stdio there
is no console, and agy v1.0.x can hard-hang before producing any output
([#6](https://github.com/yuting0624/antigravity-for-claude-code/issues/6)).

**"But agy works when I type it in my terminal!"** — yes: typed directly, agy has a real
console (interactive mode). Invoked by the plugin, it runs headless (no console). That's
the difference, not Windows vs the plugin.

What the plugin does about it: a wall-clock guard (`timeout`/`gtimeout`) turns the hang
into a clean **TIMEOUT (exit 12)** instead of a freeze, and `agy-doctor` reports "headless
hang" instead of the misleading "not authenticated".

**Fix: use WSL** (fully supported):
1. `wsl --install` (one-time; reboot)
2. Install Claude Code **and** the Antigravity CLI *inside* WSL; authenticate agy there
   (`agy models` should list models)
3. Keep your repo on the WSL Linux filesystem (`~/project`), **not** `/mnt/c/...`
4. Run `/antigravity:setup` from WSL — it should go green

---

## WSL: delegation works but is absurdly slow (20s+ for trivial calls)

**Cause:** your repo lives on a Windows mount (`/mnt/c/...`). agy reads `--dir` workspaces
over WSL's 9p bridge, which is ~10x slower than native FS.

**Fix:** move the repo into the WSL Linux filesystem (e.g. `~/projects/...`). Both the
wrapper and `agy-doctor` warn when they detect this.

---

## agy says "done" but wrote no files (or wrote them somewhere else)

**Cause:** write tasks need write permission, and headless agy's no-permission behavior
has changed across versions — but in every case **your workspace stays untouched while the
run still "succeeds"** ([#10](https://github.com/yuting0624/antigravity-for-claude-code/issues/10)):
- pre-1.1.0: only *describes* the edits
- 1.1.0–1.1.2: writes to its **own scratch dir** (`~/.gemini/antigravity-cli/scratch/`)
- 1.1.3+: **soft-denies** the write and prints a stderr notice naming the allow-rule

**Fix:**
- **Pass `--yolo`** (`--dangerously-skip-permissions`) — the one write/tool grant that
  works headless across all agy versions. (`--mode accept-edits` only wrote headless on
  1.1.0–1.1.2 and is soft-denied on 1.1.3 — don't rely on it.)
- Claude Code may prompt for (or in auto-mode, block) `--dangerously-skip-permissions` —
  approve it, or pre-allow `Bash(agy-delegate*)` in your permission settings.
- Run write tasks on a **dedicated branch** (add `--sandbox` for containment).
- **Always verify files actually changed in your workspace** (`git status`) — never trust
  the self-report. The wrapper maps a 1.1.3 soft-deny to **exit 15** so you get an
  actionable message instead of a bare "empty output".
- Long write tasks can exceed Claude Code's ~2-min synchronous Bash limit → run them as a
  background job: `ID=$(agy-job start --tier pro --dir . "<task>")`, then
  `/antigravity:status` / `/antigravity:result <id>` (interactive sessions only).

---

## Exit codes & `AGY_SIGNAL`

On classifiable failures the wrapper prints a machine-readable line to stderr:
`AGY_SIGNAL {"status":"...","reason":"...","model":"...","retry":"..."}`

| exit | meaning | what to do |
|---|---|---|
| 0 | success | — |
| 1 | usage error | check flags (`agy-delegate --help`) |
| 2 | agy failed (unclassified) | read the stderr it relayed |
| 3 | agy returned empty output | retry; check model availability (`agy models`) |
| 10 | quota / rate limit | wait, then resume the same conversation with `--continue` |
| 11 | not authenticated | run `agy` once interactively to sign in |
| 12 | timeout (agy's own, or the wall-clock guard) | raise `--timeout`, narrow the task; on Windows see the hang section above |
| 13 | agy not on PATH | install the Antigravity CLI |
| 14 | model unavailable | the `--model` / `tier_*` / `default_model` name isn't in `agy models` (agy ≥ 1.1.2 hard-fails instead of silently downgrading) — run `agy models` and fix the name |
| 15 | permission denied | agy ≥ 1.1.3 soft-denied a tool needing permission in headless mode (e.g. a file write) — pass `--yolo` and run on a branch |

---

## "tier model not in `agy models`" warning from doctor

**Cause:** agy's model list is plan-dependent (Vertex plans are Gemini-only; some plans
expose Claude/GPT). The default tier mappings may not match your plan.

**Fix:** remap tiers to models you actually have — plugin options `tier_flash` /
`tier_flash_lo` / `tier_pro` or `default_model` (exact names from `agy models`), or pass
`--model "<exact name>"` per call.

---

## Output is huge / "looks like a raw dump, not a digest"

**Cause:** the wrapper warns (stderr) when a reply exceeds `digest_warn_chars` (default
8000). Ingesting raw dumps into the conductor's context is where the cost savings die.

**Fix:** re-run with `--digest` (appends a digest-only output contract to the prompt), or
have agy summarize before you ingest. Tune the threshold via the `digest_warn_chars`
plugin option; `0` disables the warning.

---

## Updating / checking your version

Third-party marketplace plugins do **not** auto-update by default:

```
/plugin marketplace update antigravity-for-claude-code
/reload-plugins
```

`agy-doctor` prints the installed plugin version (last line of its checks). Fixes land as
version bumps — see [CHANGELOG.md](../CHANGELOG.md).

---

## Still stuck?

[Open a bug report](https://github.com/yuting0624/antigravity-for-claude-code/issues/new/choose)
— the template asks for your `agy-doctor` output, OS, and install method, which is
usually everything needed to diagnose in one round-trip.
