# Antigravity for Claude Code

Run the **Antigravity CLI (`agy`, Gemini)** as a collaborating AI inside **Claude
Code**, with **intelligent model routing across the SDLC**. Claude conducts the
judgement-heavy work and routes deterministic, high-volume work to Antigravity (the
cheaper, faster model). Two AIs, one workflow — agentic engineering, not vibe coding.

- **Claude = conductor / orchestrator** — requirements, architecture, the hard 20%
  (edge cases, integration, correctness), specs, tests/evals, final review.
- **Antigravity = delegated agent** — a full terminal agent (file edits, terminal,
  subagents, MCP, web/Vertex AI Search) that executes well-specified work.

```
you → Claude Code (conductor: requirements / architecture / verify / review)
         └── agy → Antigravity (Gemini): scaffold, tests, review, migrate, search
```

> Built on widely-discussed agentic-coding ideas — intelligent model routing, the
> conductor→orchestrator model, and "generation is solved; verification is the craft."

## What you can do

- **Route work across the SDLC** — Claude owns requirements/architecture/the hard 20%;
  Antigravity handles scaffolding, boilerplate, **test generation**, **first-pass code
  review**, and **migrations** against a shared `AGENTS.md`.
- **Use Google's built-in tools** Claude lacks natively — live **Google/web search**,
  **Vertex AI Search** over your internal/company data stores, Cloud Logging,
  notebooks, charts. Claude reviews the results and re-checks itself if unsatisfied.
- **Cross-check** — get an independent, different-model opinion or code review.
- **Scale** — offload high-volume work so Claude stays on the judgement calls.

### Lower cost — regime-dependent, measured

Routing deterministic bulk work to Gemini Flash (≪ Claude per token) is intelligent
model routing. **But it is not a flat saving:** below a break-even task size the hybrid
costs *more* (the orchestration/`cache_read` tax exceeds the cheap-token discount), and
above it lean-context routing cuts frontier-model spend by a measured margin. There is

## What's inside

```
antigravity/
├── .claude-plugin/                # plugin + marketplace manifests
├── skills/antigravity/SKILL.md    # WHEN + HOW Claude collaborates with Antigravity
├── commands/                      # slash commands: /antigravity:delegate|review|setup
├── scripts/agy-delegate.sh        # robust headless wrapper around `agy --print`
├── scripts/agy-job.sh             # background-job layer (start/status/result/cancel)
├── scripts/agy-cost-compare.sh    # optional: estimate cost saved on a task
├── scripts/measure-session.py     # COST-WEIGHTED token accounting for a session
├── scripts/doctor.sh              # health check (agy installed + authenticated)
├── tests/run-tests.sh             # dependency-free tests (stubs agy)
└── docs/                          # AB-RESULTS (the measured A/B) + DEMO-KIT
```

## Slash commands

| command | what it does |
|---|---|
| `/antigravity:setup` | health check — is `agy` installed + authenticated, scripts ready |
| `/antigravity:delegate [--tier flash\|pro] <task>` | delegate a subtask to agy under cost discipline, then verify |
| `/antigravity:review [--adversarial]` | independent cross-model review of the current diff; Claude reconciles |
| `/antigravity:status [id]` | list background delegation jobs / show one |
| `/antigravity:result <id>` | fetch a finished background job's output, then verify it |
| `/antigravity:cancel <id>` | cancel a running background job |

Background jobs (`scripts/agy-job.sh`) are for **interactive** sessions — fire a long
delegation, keep working (cache stays warm), then collect. In headless `claude -p` (one
shot) delegate **synchronously** instead; there's no later turn to collect a result.

## Tests

```bash
bash tests/run-tests.sh   # no dependencies; stubs `agy` to check arg parsing, exit codes, accounting
```

## Prerequisites

1. **Antigravity CLI** installed and authenticated:
   ```bash
   agy models     # should list Gemini models
   ```
   Config lives in `~/.gemini/antigravity-cli/settings.json` (GCP project, region,
   default model).
2. **Claude Code** (this plugin's host). For the same-bill cost benefit, run Claude
   Code on Vertex too (`CLAUDE_CODE_USE_VERTEX=1`, same project).

## Install

**From the marketplace (recommended)** — in Claude Code:
```
/plugin marketplace add yuting0624/antigravity-for-claude-code
/plugin install antigravity@antigravity-for-claude-code
```
Then run `/antigravity:setup` to confirm `agy` is installed + authenticated.

**For local development** (hacking on the plugin) — launch Claude Code pointed at a
working copy (loads the live files; `$CLAUDE_PLUGIN_ROOT` resolves correctly):
```bash
git clone https://github.com/yuting0624/antigravity-for-claude-code ~/antigravity-for-claude-code
claude --plugin-dir ~/antigravity-for-claude-code
```

## Usage

Once installed, just ask Claude Code naturally — the skill tells Claude when and how
to bring Antigravity in:

> *"Summarize every README under ./packages — get Antigravity to do the bulk reads."*
> *"Have Antigravity review this function independently and tell me if it's buggy."*

Or call the scripts directly:

```bash
# one-shot delegation (plain text on stdout)
scripts/agy-delegate.sh --tier flash "Summarize this changelog in 3 bullets: ..."

# give Antigravity a workspace for multi-file agentic work
scripts/agy-delegate.sh --tier pro --dir ./src "Find and list every TODO with file:line"

# live web / Google search (tools need --yolo in headless mode)
scripts/agy-delegate.sh --tier pro --yolo "Use web search to find <X>. Give URLs + dates."

# Vertex AI Search over internal data (discover engines, then query one)
scripts/agy-delegate.sh --tier pro --yolo "List Vertex AI Search engines (list_engines)."
scripts/agy-delegate.sh --tier pro --yolo "Search engine <ID> for: <question>. Cite hits."

# cross-model review
scripts/agy-delegate.sh --tier pro "Review for bugs, be skeptical: <paste>"

# read a long prompt from stdin
cat big-prompt.txt | scripts/agy-delegate.sh -

# cost demo
scripts/agy-cost-compare.sh --tier flash "Extract all emails from: ..."
```

### Tiers
| tier | model | use for |
|------|-------|---------|
| `flash` (default) | Gemini 3.5 Flash (High) | most bulk work |
| `flash-lo` | Gemini 3.5 Flash (Low) | cheapest, trivial tasks |
| `pro` | Gemini 3.1 Pro (High) | harder reasoning / cross-checks |

## Cost demo: read the fine print

`agy-cost-compare.sh` estimates tokens from **character count** (agy v1.0.x exposes
no token API in `--print` mode), so figures are **ballpark, not billing-accurate**.
Prices are **placeholders** — set the real Vertex rates before quoting anyone:

```bash
CLAUDE_IN_PER_M=... CLAUDE_OUT_PER_M=... \
GEMINI_IN_PER_M=... GEMINI_OUT_PER_M=... \
scripts/agy-cost-compare.sh "task"
```

It prices the *same* measured volume at both decks to show the per-token gap. Real
savings are **larger**, because the orchestrator processes far fewer tokens than
Claude-does-everything.

## Guardrails

- Always **verify** Antigravity's output — Flash is weaker than Claude. Review diffs
  before trusting file edits.
- `--yolo` (`--dangerously-skip-permissions`) auto-approves every tool call. Only use
  it with `--sandbox` or in a throwaway directory.
- Hand off **big chunks**: tiny round-trips lose to prompt/parse overhead.

## Known limits (agy v1.0.x)

- `-p`/`--print`/`--prompt` **takes the prompt as its value** and must come last
  (`agy --model X -p "prompt"`). The wrapper handles this; don't reorder.
- No `--output-format json` — output is plain text.
- `--print` drops stdout on a non-TTY unless stdin is detached; the wrapper handles
  this with `< /dev/null`.
- No `timeout(1)` on macOS — use the wrapper's `--timeout` (maps to
  `agy --print-timeout`).

## Measured cost reality (don't quote flat ratios)

This plugin's cost claim is **regime-dependent and measured**, not a slide figure:
- **Small task:** the hybrid costs *more* than solo Claude (orchestration overhead > the
  cheap-token discount).
- **Large task** (multi-agent ADK build + eval, measured): hybrid was **~27% cheaper than
  solo Claude @ high effort and ~64% cheaper than @ max**, at equal quality (same eval
  gate) — and the cheap Gemini work isn't even counted.

See [`docs/AB-RESULTS.md`](docs/AB-RESULTS.md) for the full A/B (Tests 1 & 2).

## Disclaimer

Community project. **Not affiliated with, endorsed by, or supported by Google or
Anthropic.** "Antigravity", "Gemini", "Claude", and "Claude Code" are trademarks of their
respective owners. This plugin orchestrates the third-party `agy` CLI from Claude Code; you
are responsible for your own API/cloud costs, credentials, and data-sharing choices. MIT
licensed — see [LICENSE](LICENSE).
