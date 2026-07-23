<div align="center">

# 🛰️ Antigravity for Claude Code

**Run the Antigravity CLI (Gemini) as a collaborating sub-agent, right inside Claude Code.**
![Antigravity for Claude Code — Claude directs, Gemini executes](docs/hero.png)
Claude conducts the judgement; Gemini does the heavy lifting — intelligent model routing across the SDLC.

[![CI](https://github.com/yuting0624/antigravity-for-claude-code/actions/workflows/ci.yml/badge.svg)](https://github.com/yuting0624/antigravity-for-claude-code/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-5A4FCF?logo=claudecode&logoColor=#D97757)
[![Antigravity CLI](https://img.shields.io/badge/Antigravity%20CLI-agy-4285F4?logo=googlegemini&logoColor=white)](https://antigravity.google/docs/cli-using)

</div>

---

## ⚡ Quick look

![Antigravity for Claude Code demo](docs/demo.gif)

Claude stays the conductor; the bulk, token-heavy read ran on cheaper Gemini, and Claude verified the result.

---

## 💡 Why

| | Claude (conductor) | Gemini / `agy` (executor) |
|---|---|---|
| **Owns** | requirements · architecture · the hard 20% · **verification** · review | scaffold · implementation · test generation · search |
| **Strength** | judgement | cheap, fast throughput |

```
you → Claude Code (conduct: design / verify / review)
         └── agy → Gemini (execute: implement / test / search)
```

> *Generation is solved; verification, judgement, and direction are the craft.*

## ✨ What it does

- **Routes work across the SDLC** — Claude keeps the judgement calls; Antigravity handles scaffolding, **test generation**, **first-pass review**, and **migrations** under a shared `AGENTS.md`.
- **Adds tools Claude lacks natively** — live **Google/web search**, **Vertex AI Search** over your internal data, deep research, Cloud Logging. Claude reviews and re-checks the results.
- **Cross-model verification** — an independent, different-model opinion on your code.
- **Background jobs** — fire a long delegation, keep working, collect later.
- **Internal fan-out** — one delegation, and agy spawns its own subagents on the cheap side (dynamic `define_subagent` on agy ≥ 1.0.16; `TypeName "self"` + Role on any version); each leaves a **readable trajectory** you audit with `agy-trace`.
- **Built-in cost discipline** — measured, not guessed (see below).
- **Drops in with the discipline on** — a `SessionStart` hook injects the *cost-aware*
  routing policy automatically (toggle in plugin settings), and the `antigravity-delegate`
  subagent does file **writing** on Gemini, so Claude spends **no tokens generating file contents**.
- **No slash command required** — the delegate subagent is picked up **proactively** for bulk
  work, and a prompt-level nudge flags bulk-looking requests as delegation candidates.
  Both are advisory: **the break-even judgment stays with Claude** (full auto-routing is a
  measured net loss below the break-even), and the nudge is toggleable (`delegation_nudge`).

## 📊 Measured results

On a **large** ADK multi-agent build (+ `adk eval`), same task / same model, 3 ways:

| | Claude solo @high | solo @max | **hybrid** |
|---|---|---|---|
| frontier cost (COST-WEIGHTED) | 2.62M | 5.34M | **1.91M** |
| quality (`adk eval`) | ✅ 3/3 | ✅ 3/3 | ✅ **3/3** |

→ **−27% vs solo@high, −64% vs solo@max, at equal quality** — and the cheap Gemini work isn't even counted. Savings scale with task size; tiny one-off tasks are cheaper to just run on Claude. Full A/B: [`docs/AB-RESULTS.md`](docs/AB-RESULTS.md).

> **Note on cost figures:** numbers are **estimates** — token counts are approximated and rates live in [`prices.json`](prices.json). **Set your real Vertex rates there before quoting any figure.**

## 🚀 Install

In Claude Code:
```
/plugin marketplace add yuting0624/antigravity-for-claude-code
/plugin install antigravity@antigravity-for-claude-code
/antigravity:setup        # verifies agy is installed + authenticated
```

**Prerequisites:** the [Antigravity CLI](https://antigravity.google/docs/cli-using) (`agy`) installed & authenticated (`agy models` lists Gemini models), and Claude Code. For the same-bill cost benefit, run Claude Code on Vertex too.

**Platform support:** macOS, Linux, and **WSL** are the supported targets for headless delegation. **Native Windows (Git Bash/MSYS) is not recommended** — `agy -p` can hang with a 0-byte log when run without a real console (ConPTY); see [issue #6](https://github.com/yuting0624/antigravity-for-claude-code/issues/6). The wrapper now bounds this with a wall-clock guard (GNU `timeout`/`gtimeout`, returning a clean TIMEOUT instead of hanging), and `doctor` distinguishes a hang from an auth failure — but for reliable headless use, run from **WSL/macOS/Linux**.

## 🧩 Slash commands

<img src="docs/image.png" alt="The /antigravity slash commands in a Claude Code terminal session" width="720">

*The plugin's commands show up natively in Claude Code's `/` menu.*

| command | what it does |
|---|---|
| `/antigravity:setup` | health check — `agy` installed + authenticated, scripts ready |
| `/antigravity:delegate [--tier flash\|pro] <task>` | delegate a subtask to agy under cost discipline, then verify |
| `/antigravity:review [--adversarial]` | independent cross-model review of the current diff; Claude reconciles |
| `/antigravity:research <topic>` | Claude-orchestrated deep research — agy does grounded web legwork, Claude verifies citations across ≥2 sources |
| `/antigravity:cloud-run-debug [--service <s>] [--region <r>] [--project <id>] [--since 1h] [--apply]` | diagnose a failing Cloud Run service — agy digests the error logs, Claude infers the root cause + fix; read-only by default (`--apply` writes to a branch) |
| `/antigravity:status [id]` · `:result <id>` · `:cancel <id>` | manage background delegation jobs |

> Background jobs are for **interactive** sessions (fire-and-collect). In headless `claude -p` (one-shot), delegate **synchronously** — there's no later turn to collect a result.

---

<details>
<summary><b>🛠️ Direct script usage &amp; tiers</b></summary>

```bash
# one-shot delegation (plain text on stdout)
scripts/agy-delegate.sh --tier flash "Summarize this changelog in 3 bullets: ..."

# give Antigravity a workspace for multi-file agentic work
scripts/agy-delegate.sh --tier pro --dir ./src "List every TODO with file:line"

# bulk read -> digest-only reply (the biggest cost lever; wrapper warns on dump-sized replies)
scripts/agy-delegate.sh --digest --dir . "Map the auth flow end to end"

# write task: --yolo is the reliable headless write grant (run on a branch; verify git status)
scripts/agy-delegate.sh --yolo --dir ./app "Implement X per SPEC.md"

# live web / Google search (tools need --yolo in headless mode)
scripts/agy-delegate.sh --tier pro --yolo "Web-search <X>. Give URLs + dates."

# Vertex AI Search over internal data
scripts/agy-delegate.sh --tier pro --yolo "List Vertex AI Search engines (list_engines)."

# cross-model review / stdin / background job
scripts/agy-delegate.sh --tier pro "Review for bugs, be skeptical: <paste>"
cat big-prompt.txt | scripts/agy-delegate.sh -
ID=$(scripts/agy-job.sh start --tier pro --dir . "big task"); scripts/agy-job.sh result "$ID"
```

| tier | model | use for |
|------|-------|---------|
| `flash` (default) | Gemini 3.6 Flash (High) | most bulk work |
| `flash-lo` | Gemini 3.6 Flash (Low) | cheapest, trivial tasks |
| `pro` | Gemini 3.1 Pro (High) | harder reasoning / cross-checks |

**agy is multi-model.** Tiers default to Gemini, but you can use any model `agy models` lists
(Claude / GPT on plans that expose them): pass `--model "<exact name>"`, or set it persistently
via plugin options — `default_model`, or per-tier `tier_flash` / `tier_flash_lo` / `tier_pro`
(env `CLAUDE_PLUGIN_OPTION_*`). Keep the executor a *different, cheaper* model than the Claude
conductor — that's what gives both the cost saving and the cross-model verification.

> **Verified through agy 1.1.5.** A newer **Gemini 3.6 Flash** now shows up in `agy models` and works — the `flash` default stays on **Gemini 3.5 Flash (High)** for broad plan availability (newer models can lag on enterprise Vertex); remap `tier_flash` to `Gemini 3.6 Flash (High)` when your plan serves it. (agy 1.1.5 switched `agy models` to slugs like `gemini-3.5-flash`; both slugs and display names work with `--model`, and `doctor` matches either.)

</details>

<details>
<summary><b>💸 How to actually get the savings (cost discipline)</b></summary>

Delegation doesn't save money by itself — these do (also in the skill):

1. **Delegate above the break-even** — bulk/parallel/repetitive work, not tiny tasks.
2. **Keep Claude's context lean** — don't re-read what agy already handled; take a **digest**, not raw output. (Biggest lever — it collapses `cache_read`.) Enforced in code: `--digest` appends a digest-only output contract, and the wrapper **warns when a reply comes back dump-sized** (tune via the `digest_warn_chars` plugin option).
3. **Batch** — one big delegation beats many round-trips.
4. **Review the diff, not the whole tree.**

`scripts/measure-session.py <session-id>` prints the COST-WEIGHTED + est. USD breakdown for a session (Claude side; Gemini side priced separately). `scripts/agy-cost-compare.sh` shows the per-token gap for a task — **estimates from char-count, so verify `prices.json` first.**

**Running a PoC in your org?** [`docs/POC-PLAYBOOK.md`](docs/POC-PLAYBOOK.md) is the step-by-step method — quality gate first, baseline, one lever at a time, break-even reporting, and org-level rollout/enforcement (incl. Windows/WSL requirements).

</details>

<details>
<summary><b>🚧 Guardrails &amp; known limits</b></summary>

> **Something broken?** See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — symptom-first fixes for Windows/WSL, writes that silently don't happen, quota/auth/timeout codes, and updating.

**Guardrails**
- Always **verify** agy's output (it can be wrong, and may even alter its environment to make a check pass — re-run gates yourself in a clean state).
- `--yolo` auto-approves every tool call — use with `--sandbox` or in a throwaway dir.
- Write tasks: run on a dedicated branch/worktree, review the diff before merging.

**Known limits (agy v1.0.x)**
- `-p`/`--print` **takes the prompt as its value** and must come last — the wrapper handles this.
- No `--output-format json` (plain text); `--print` drops stdout on a non-TTY unless stdin is detached (handled via `< /dev/null`).
- **Writes need `--yolo`:** headless agy's no-permission behavior keeps shifting (describe-only pre-1.1.0 · scratch-divert 1.1.0–1.1.2 · soft-deny 1.1.3+), but every version leaves **your workspace untouched while the run still "succeeds"** ([issue #10](https://github.com/yuting0624/antigravity-for-claude-code/issues/10)). The durable grant is **`--yolo`** (`--dangerously-skip-permissions`) — `--mode accept-edits` only wrote headless on 1.1.0–1.1.2. Run write tasks on a branch and verify with `git status`; the wrapper maps a 1.1.3 soft-deny to exit `15`. Long write tasks can exceed the ~2-min sync Bash limit → use a background job.
- **Native Windows (no ConPTY):** headless `agy -p` / `agy models` can hard-hang with a 0-byte log when stdio is redirected ([issue #6](https://github.com/yuting0624/antigravity-for-claude-code/issues/6)). The wrapper wraps agy in a wall-clock `timeout`/`gtimeout` guard so it returns a structured TIMEOUT (exit 12) instead of hanging; `doctor` reports the likely hang instead of a misleading "not authenticated". Without `timeout` on PATH there's no safety net — use **WSL/macOS/Linux** for headless delegation.
- **WSL:** running agy with `--add-dir` on a Windows mount (`/mnt/c/...`) is very slow — agy reads the workspace over a 9p bridge, so even trivial calls can take 20s+. Keep the repo on the WSL Linux filesystem (`~`). The wrapper and `doctor` warn about this.

</details>

<details>
<summary><b>📦 What's inside · local dev · tests</b></summary>

```
.claude-plugin/   plugin (+ userConfig: default_tier, timeout, coding_policy) + marketplace manifests
skills/antigravity/SKILL.md   WHEN + HOW Claude collaborates with agy
agents/           antigravity-delegate subagent (file work runs on Gemini, not Claude)
commands/         slash commands (delegate, review, research, cloud-run-debug, setup, status, result, cancel)
hooks/            SessionStart: agy health check + auto-inject the cost-aware policy
scripts/          agy-delegate · agy-job · agy-cost-compare · cloud-debug · agy-trace · measure-session · doctor
docs/             AB-RESULTS (measured A/B) · POC-PLAYBOOK · TROUBLESHOOTING · DEMO-KIT
prices.json       Vertex rate config (verify before quoting)
```

**Local development** (hack on the plugin — loads live files, `$CLAUDE_PLUGIN_ROOT` resolves):
```bash
git clone https://github.com/yuting0624/antigravity-for-claude-code ~/antigravity-for-claude-code
claude --plugin-dir ~/antigravity-for-claude-code
```

**Tests** (no dependencies; stubs `agy`):
```bash
bash tests/run-tests.sh
```

</details>

---

## 🤝 Contributing

Early-stage and MIT — issues, PRs, and ⭐ all welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [`good first issue`](https://github.com/yuting0624/antigravity-for-claude-code/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) list.

---

## ⚠️ Disclaimer

Community project. **Not affiliated with, endorsed by, or supported by Google or Anthropic.** "Antigravity", "Gemini", "Claude", and "Claude Code" are trademarks of their respective owners. This plugin orchestrates the third-party `agy` CLI; you are responsible for your own API/cloud costs, credentials, and data-sharing choices. MIT licensed — see [LICENSE](LICENSE).
