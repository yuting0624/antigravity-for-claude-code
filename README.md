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

> Grounded in Google's *"The New SDLC With Vibe Coding"* (May 2026): intelligent
> model routing, the conductor→orchestrator model, and "generation is solved;
> verification is the craft."

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
**no flat 8×/46%** — quote the measured number and the break-even, not a headline ratio.
See [`docs/AB-RESULTS.md`](docs/AB-RESULTS.md) for the data and the [`## Cost discipline`]
rules in the skill for how to actually get the savings.

## What's inside

```
antigravity/
├── .claude-plugin/plugin.json     # plugin marker (name: antigravity)
├── skills/antigravity/SKILL.md    # WHEN + HOW Claude collaborates with Antigravity
├── scripts/agy-delegate.sh        # robust headless wrapper around `agy --print`
└── scripts/agy-cost-compare.sh    # optional: estimate cost saved on a task
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

**Local (quickest for trying / demo):**
```bash
git clone <this-repo> ~/antigravity-for-claude-code
chmod +x ~/antigravity-for-claude-code/scripts/*.sh
```
Then add it as a local plugin in Claude Code (`/plugin`), or copy the skill in:
```bash
cp -r ~/antigravity-for-claude-code/skills/antigravity ~/.claude/skills/
```

**Shared (for the team / marketplace):** publish this repo and reference it from a
`marketplace.json`; colleagues then run `/plugin install antigravity`.

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

See [`docs/AB-RESULTS.md`](docs/AB-RESULTS.md) for the full A/B (Tests 1 & 2). Quote the
break-even and the measured % — never a flat "8×/46×".

## Disclaimer

Community project. **Not affiliated with, endorsed by, or supported by Google or
Anthropic.** "Antigravity", "Gemini", "Claude", and "Claude Code" are trademarks of their
respective owners. This plugin orchestrates the third-party `agy` CLI from Claude Code; you
are responsible for your own API/cloud costs, credentials, and data-sharing choices. MIT
licensed — see [LICENSE](LICENSE).
