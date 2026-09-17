<div align="center">

# 🛰️ Antigravity for Claude Code

**Delegate the reading to Gemini. Keep the judgement on Claude.**
![Antigravity for Claude Code — Claude directs, Gemini reads](docs/hero.png)
A local MCP server, shipped in the plugin, reads your codebase, your diffs, your recordings and long documents — and only a digest with `file:line` references comes back.

[![CI](https://github.com/yuting0624/antigravity-for-claude-code/actions/workflows/ci.yml/badge.svg)](https://github.com/yuting0624/antigravity-for-claude-code/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-5A4FCF?logo=claudecode&logoColor=#D97757)
[![Vertex AI](https://img.shields.io/badge/Vertex%20AI-Gemini-4285F4?logo=googlegemini&logoColor=white)](https://cloud.google.com/vertex-ai)

</div>

---

## 💡 Why

Claude Code's cost in a long session is Claude re-reading its own growing context on
every turn. The lever is not a cheaper model for Claude — it is **what Claude never has to
read**. This plugin hands the bulky reading to a long-context model on Vertex AI and
carries a digest instead of the corpus.

| | Claude (conductor) | the delegation server (reader) |
|---|---|---|
| **Owns** | requirements · design · edits · running the gate · **verification** · review | digesting a codebase · read-only tasks over files · second review of a diff · recordings and long documents |
| **Strength** | judgement | cheap, long context |
| **Writes files** | yes | **never** |

```
you → Claude Code (conduct: design / edit / verify / review)
         └── delegation MCP server (read: digest / extract / review)
                  └── Gemini on Vertex AI, or your organisation's gateway
```

> *Generation is solved; verification, judgement, and direction are the craft.*

## ✨ What it does

- **`digest_codebase`** — a question about, or orientation in, a selection of files. Respects
  `.gitignore`, skips binaries, media and lockfiles, redacts credential-shaped strings, and
  returns a digest with `file:line` references under a token budget.
- **`delegate_task`** — a read-only deliverable: an inventory, an extraction, a comparison,
  a migration list — with a *Verify this* list. It never modifies files.
- **`review_diff`** — an independent second read of a change from a **different model
  family**, each finding anchored to a line shown in the diff, with a verdict.
- **`digest`** — recordings, video, images, PDFs and long documents, with timestamps or
  page citations. Claude can't hear or watch; this can.
- **`search_web`** — grounded web research (Google Search on Vertex AI): dated, URL-cited
  findings and the sources actually used, one call per research sub-question.
- **Background jobs** — `async: true` returns a job id; very large selections run as
  Vertex **batch** jobs that survive a restart.
- **Drops in with the discipline on** — a `SessionStart` hook injects the cost-aware
  routing policy, a prompt-level nudge flags bulk reads, and the `antigravity-delegate`
  subagent has *only* the server's tools, so a delegated read cannot inflate its context.
  All advisory: **the break-even judgment stays with Claude.**
- **Nothing to install besides the plugin.** The server is `server/index.js`; Claude Code
  starts it. Node.js 20+ and Google Cloud credentials are the prerequisites.

## 📊 Measured results

Numbers from this repository's own verification (`gemini-studio-mcp`, criteria 8–13, live
against Vertex AI, 2026-09-15):

| what | in | out | notes |
|---|---|---|---|
| digest of this plugin's server source | **173,239 tokens** | **1,471 tokens** | 100% of references resolve to a real line; 5 s; one request |
| the same selection, forced through 5 chunks + merge | 183k | 2,133 | map-reduce keeps the budget and the references |
| the same question a third time | cached | — | **$0.024 vs $0.206** inline — a Vertex context cache created lazily on the second request |
| 62k-token corpus (0.x measurement, same pattern) | 62k | 4.4k carried | every later turn re-sent 4.4k instead of 62k |

And the caveat that has held since 0.x: **below the break-even the hybrid costs more.**
Roughly: three files or ~20k tokens is worth a digest; under ~6k tokens it is not.
`savings_report` totals what has been kept out of context; `measure-session.py --join`
shows both sides of a session. Older execution-delegation A/Bs are in
[`docs/AB-RESULTS.md`](docs/AB-RESULTS.md) — they are why 1.0 delegates reading, not execution.

## 🚀 Install

In Claude Code:
```
/plugin marketplace add yuting0624/antigravity-for-claude-code
/plugin install antigravity@antigravity-for-claude-code
/antigravity:setup        # node, the server bundle, credentials, where requests go
```

**Prerequisites:** Node.js 20+ on PATH, and Google Cloud credentials for a project with
Vertex AI enabled (`gcloud auth application-default login`) — or the credential your
organisation's gateway expects. The server's settings (project, driver, aliases, allowed
hosts) live in `~/.gemini-mcp/config.json` or in a managed `managed-mcp.json`; the plugin
itself has three options (`coding_policy`, `delegation_nudge`, `usage_log`).

**Platform support:** macOS, Linux, WSL. Native Windows works for the server; `git`
must be on PATH for `digest_codebase` selections inside repositories.

## 🔒 Where requests go — and where they cannot

This server reads your files and sends their text to a model endpoint, so **which hosts
may receive that text is an allowlist the organisation controls**
(`DELEGATION_ALLOWED_HOSTS`, default `*.googleapis.com`, `*.gateway.dev`), the outbound
twin of the selection `root`. To use your organisation's gateway or another provider, add
its hostname; a request to anything else is refused with `PERMISSION (15)` and the host
named. Every response ends with one factual line: `endpoint: geap (aiplatform.googleapis.com)`
or `endpoint: external (host)`. `/antigravity:setup` shows the allowlist and flags any
external destination in the current configuration.

Three ways the server can be pointed, all through the same alias table (`ingest` /
`review` / `cheap` — tools never name a model; an alias written `anthropic/<model>` is
Claude on Vertex AI, so a role can change model family without leaving the platform):

| Mode | Who resolves the alias | What travels |
|---|---|---|
| **Vertex AI, direct** (default) | the server, from its config | billing labels, context cache, fallback chain |
| **Vertex passthrough gateway** (recommended for organisations) | the server; the proxy adds IAM, quota, logging | the full Vertex request, unchanged |
| **Compatibility mode** (OpenAI-style gateway) | the gateway: the alias is sent as `model` | `chat/completions`; no cache, batch or media |

Details, every setting, and the reasons some features are Vertex-only are in the server's
README: [gemini-studio-mcp](https://github.com/yuting0624/gemini-studio-mcp).
Organisation samples are in [`deploy/`](deploy/).

## 🧩 Slash commands

| command | what it does |
|---|---|
| `/antigravity:setup` | node, the shipped server, credentials, gateway, egress allowlist, which model each alias answers with |
| `/antigravity:delegate <question or task> [paths]` | digest a selection (`digest_codebase`) or run a read-only task (`delegate_task`), then verify the references |
| `/antigravity:review [--adversarial] [range] [paths]` | independent second review of a change (`review_diff`); Claude reconciles |
| `/antigravity:media <file> [focus]` | recordings, video, images, PDFs → timestamped / cited digest (`digest`) |
| `/antigravity:cloud-run-debug [--service <s>] [--region <r>] [--since 1h] [--cluster] [--apply]` | diagnose a failing Cloud Run service — logs digested on the cheap side, Claude infers the root cause; read-only by default |
| `/antigravity:status [id]` · `:result <id>` · `:cancel <id>` | background jobs (in-process and Vertex batch) |
| `/antigravity:research <topic>` | multi-source research: `search_web` (Google Search grounding on Vertex AI) fans out per sub-question, Claude verifies citations across ≥2 sources and synthesizes |
| `/antigravity:migrate [--apply] [--include-repos]` | move an existing Claude Code setup onto the Antigravity CLI — unrelated to the transport, still shipped |

> Background jobs are for **interactive** sessions. In headless `claude -p` (one-shot),
> call synchronously — there is no later turn to collect a result.

## 🧾 What each call leaves behind

Counts only — never file names, prompts or content:

1. **The response footer**: `usage: {…}`, `offload: {…}` (what was kept out of Claude's
   context and what that was worth), `endpoint: …`.
2. **The server's ledger** (`~/.gemini-mcp/ledger.jsonl`) and, when talking to Vertex
   directly, **Cloud Logging** in your project (`delegation.usage`). Vertex requests carry
   billing labels (`delegation-tool`, `delegation-alias`) and a `User-Agent:
   delegation-mcp/<version>`, so the billing export breaks cost down by tool.
3. **The plugin's usage log** (`~/.antigravity-usage.jsonl`, `usage_log` option): a
   `PostToolUse` hook joins Claude's session id with the server's per-call usage.
   `scripts/measure-session.py <session> --join` prints the Claude side and the
   delegation side of one session together.

Nothing is reported to anyone but your project or your gateway.

<details>
<summary><b>🏢 Deploying for an organisation</b></summary>

Ship the same bundle two ways and control both from managed settings:

- **`managed-mcp.json`** (macOS `/Library/Application Support/ClaudeCode/managed-mcp.json`,
  Linux `/etc/claude-code/managed-mcp.json`) declares the server with its driver,
  gateway, allowed hosts and allowed roots — developers cannot change these.
- **Managed settings** force-enable the plugin for the Conductor side (skill, hooks,
  commands, subagent) and pre-approve the tools:
  `permissions.allow: ["mcp__delegation__*"]` for a server named `delegation` in
  `managed-mcp.json`, or `mcp__plugin_antigravity_delegation__*` for the plugin-bundled one.

For an InfoSec review, three lines: **what is read** — text files under the selection
`root` (and, when set, `DELEGATION_ALLOWED_ROOTS`), after `.gitignore`, a built-in ignore
list and credential redaction; **where it is sent** — only hosts on
`DELEGATION_ALLOWED_HOSTS`, Google's managed endpoints by default; **who controls it** —
the managed configuration, not the developer's machine.

Samples: [`deploy/managed-mcp.json`](deploy/managed-mcp.json),
[`deploy/managed-settings.json`](deploy/managed-settings.json), and the Vertex passthrough
proxy (Cloud Run + Terraform) in the server repository under
`deploy/gateway-vertex-passthrough/`.

</details>

<details>
<summary><b>💸 How to actually get the savings (cost discipline)</b></summary>

Delegation doesn't save money by itself — these do (also in the skill):

1. **Delegate above the break-even** — three files or ~20k tokens and up; not tiny reads.
2. **Ingest the digest, never the corpus** — open only the `file:line` references you
   must verify. This is the lever; it is what collapses per-turn `cache_read`.
3. **One call per selection** — ask both questions in one call. A repeated selection gets
   a context cache on the second request (`cache: "on"` to create it up front).
4. **Keep `token_budget` honest** — the default 4000 is what you carry on every later turn.
5. **Review the diff, not the tree.**

**Running a PoC in your org?** [`docs/POC-PLAYBOOK.md`](docs/POC-PLAYBOOK.md) is the
method — quality gate first, baseline, one lever at a time, break-even reporting.

</details>

<details>
<summary><b>🚧 Guardrails &amp; known limits</b></summary>

> **Something broken?** See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

- **A digest is a claim, not evidence.** The server checks that every reference points at
  a real line (`stats.refs_valid_ratio`), not that the claim is true. Open the references
  behind anything load-bearing; run the gate yourself.
- **The server only reads**, only under `root`. What comes back is bounded by
  construction — a schema with no content field, a token budget, hard caps, a verbatim-run
  detector, a second redaction pass — and every guard that fired is in `stats`.
- **Redaction is a net, not a guarantee.** Credential-shaped strings are removed by
  pattern before sending; review what a selection contains before pointing the server at
  a tree with secrets in plain files.
- **Batch jobs** stage the redacted selection as JSONL in the project's Cloud Storage
  bucket for the life of the job and delete it afterwards.
- **Selections are bounded:** 400 files, 512 KB per file, ~2M tokens interactive.
- **Not carried from 0.x:** write/scaffold delegation (by design), internal fan-out,
  `agy-trace`, `agy-cost-compare`. See [`docs/MIGRATION-1.0.md`](docs/MIGRATION-1.0.md).

</details>

<details>
<summary><b>📦 What's inside · local dev · tests</b></summary>

```
.claude-plugin/   plugin manifest: the delegation MCP server + 3 options
server/           the delegation server bundle (index.js, prices.json, VERSION) — scripts/sync-server.sh refreshes it
skills/antigravity/SKILL.md   WHEN + HOW Claude delegates reading, and verifies
agents/           antigravity-delegate subagent (only the server's tools)
commands/         delegate, review, media, cloud-run-debug, setup, status, result, cancel, research, migrate
hooks/            SessionStart (server check, policy), UserPromptSubmit (nudge), PostToolUse (usage join)
bin/              delegation-cli · delegation-doctor · cloud-debug · measure-session · agy-tier · agy-condense · agy-migrate
scripts/          the above, plus sync-server.sh and agy-log-cluster.py (cloud-run-debug --cluster)
deploy/           managed-mcp.json / managed-settings.json samples for organisations
docs/             MIGRATION-1.0 · TROUBLESHOOTING · POC-PLAYBOOK · AB-RESULTS · DEMO-KIT
```

**Local development** (loads live files, `$CLAUDE_PLUGIN_ROOT` resolves):
```bash
git clone https://github.com/yuting0624/antigravity-for-claude-code ~/antigravity-for-claude-code
claude --plugin-dir ~/antigravity-for-claude-code
```

**Tests** (bash, python3, node; no network):
```bash
bash tests/run-tests.sh
```
The server has its own suite in its repository (`scripts/verify.sh`), offline and live.

</details>

---

## 🗳️ The same two models, arranged differently

This plugin is one shape of Claude and Gemini working together — **conductor and
reader** — for people who live in a terminal. The server it ships,
[**gemini-studio-mcp**](https://github.com/yuting0624/gemini-studio-mcp), is the same
thesis on the other surface, **Claude Desktop**: the verb has been *ingest* there from the
start — Gemini reads the recording, the PDF corpus, the internal search index, and only the
digest reaches Claude. 1.0 brings that verb here.

[**quorum-review**](https://github.com/yuting0624/quorum-review) is the third shape: the
two as **peers**. Both read the same pull request independently; where they agree
independently *that is the result*. It runs on every pull request opened here. Its
lesson also applies to `review_diff`: two independent scans insure you against *one
model's* blind spot — not against a gap in what you handed **both** of them.

---

## 🤝 Contributing

MIT — issues, PRs, and ⭐ welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

**Automated review:** PRs get a Claude review carrying this repo's own contracts, and
quorum-review. From a fork, the Claude review runs only once a maintainer with write
access applies the `claude-review` label; the reviewer sees your code as a diff and
nothing of yours is executed.

---

## ⚠️ Disclaimer

Community project. **Not affiliated with, endorsed by, or supported by Google or
Anthropic.** "Gemini", "Vertex AI", "Claude", and "Claude Code" are trademarks of their
respective owners. You are responsible for your own cloud costs, credentials, and
data-sharing choices. MIT licensed — see [LICENSE](LICENSE).
