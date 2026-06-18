---
name: antigravity
description: Run the Antigravity CLI (Gemini) as a collaborating AI inside Claude Code, with intelligent model routing across the software development lifecycle. Claude is the conductor/orchestrator — requirements, architecture, the hard 20%, verification, and review — and routes deterministic, high-volume work (scaffolding, boilerplate, test generation, first-pass review, migrations, web/Vertex AI Search) to Antigravity (Gemini), the cheaper, faster model. Use when the user wants to "use Antigravity / agy", "vibe code / agentic engineering", "accelerate the SDLC", "delegate to Gemini", "scaffold / generate tests / migrate", "first-pass code review", "search web or internal/company data", "deep research / multi-source research report", "second-model cross-check", or "lower token cost on a big job". Claude always verifies Antigravity's output and re-checks itself if unsatisfied.
version: 0.7.1
---

# Antigravity for Claude Code — hybrid SDLC

Run the **Antigravity CLI (`agy`, Gemini)** as a second AI working alongside Claude
Code. The organizing idea is **intelligent model routing across the SDLC**: keep
judgement-heavy work on Claude (the frontier model) and route deterministic,
high-volume work to Antigravity (cheaper, faster Gemini). Two AIs, one workflow.

- **Claude = conductor / orchestrator** — requirements, architecture, the hard 20%
  (edge cases, integration, correctness), specs, tests/evals, final review.
- **Antigravity = delegated agent** — a full terminal agent (file edits, terminal,
  subagents, MCP, web/Vertex AI Search) that executes well-specified work.

This is **agentic engineering, not vibe coding**: the value is the structure around
the model — routing, shared rules, verification gates — not raw generation.
*Generation is solved; verification, judgement, and direction are the craft.*

## Two modes (pick per task)

- **Conductor (sync, inline):** you're shaping something in real time; delegate a
  small, well-scoped chunk to agy mid-flow (e.g. "generate these tests"), use the
  result immediately.
- **Orchestrator (async, multi-unit):** decompose a larger task into units, dispatch
  to agy (often with `--dir`, agentic, in parallel), then review and integrate.
  Best for migrations, bulk implementation against patterns, test suites.

## Division of labor across the SDLC

Route each phase to the right model. This is the core policy.

| SDLC phase | Owner | Why |
|---|---|---|
| Requirements & planning | **Claude** | ambiguity, human-paced judgement |
| Design & architecture | **Claude** | trade-offs; most human-centric |
| Implementation — complex / architecture-bearing (the 20%) | **Claude** | correctness, deep context |
| Implementation — scaffolding / boilerplate / well-specified | **agy** | deterministic, high volume |
| Test & eval generation | **agy** (Claude defines the contract) | cheaper-model territory |
| First-pass code review | **agy** → **Claude** final | AI as first-pass reviewer |
| Cross-model verification (output + trajectory) | **both** | two model families ≠ same failure |
| Maintenance / migration / modernization | **agy** executes, **Claude** directs | tedious, systematic |
| Web / Vertex AI Search | **agy** → **Claude** re-checks | tools Claude lacks natively |
| Deep research (multi-source) | **agy** fans out search/fetch · **Claude** plans, verifies ≥2 sources, synthesizes | offload bulky pages to cheap Gemini; frontier model judges |

Routing tier within agy: `flash` (default, bulk) · `flash-lo` (cheapest, trivial) ·
`pro` (harder reasoning / reviews / cross-checks).

## How to call it

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/agy-delegate.sh" [options] "the task prompt"
```
Options: `--tier flash|flash-lo|pro` · `--dir <path>` (workspace, repeatable) ·
`--timeout 10m` · `--yolo` (auto-approve tools — needed for any tool use in headless
mode) · `--sandbox` · pipe a long prompt with a trailing `-`.

The wrapper handles agy's quirks (prompt is the value of `-p`; non-TTY stdout drop via
`< /dev/null`; no `--output-format json`, so output is plain text you parse).

**If Claude itself is running headless (`claude -p`, one-shot):** run delegations
**synchronously** — let `agy-delegate.sh` BLOCK and return before you continue. Do NOT
background a delegation expecting a later turn / "harness re-invocation": there is none in
`-p` mode, so you'd exit before the work finishes. (Backgrounding is only valid in an
interactive session that will be re-invoked.)

## Shared harness: one AGENTS.md for both AIs

agy **reads `AGENTS.md`** from the workspace (verified). Keep a single shared
`AGENTS.md` at the repo root (stack, conventions, hard rules, workflow) so Claude and
Antigravity operate under the **same rules** — this raises agy's first-pass success
rate and keeps output consistent (lower OpEx).

**Rule: when delegating any repo work, always pass `--dir <repo-root>`** so agy loads
AGENTS.md and the real code, instead of pasting files into the prompt (cheaper, denser
context).

## Verification gates (non-negotiable)

Claude owns correctness. For anything that ships:
1. **Define the contract first** — Claude writes/owns the tests and evals; they tell
   agy what "correct" means more precisely than prose.
2. **Output eval = actually run it, don't stop at reading the code.** Reading the diff
   is necessary but NOT sufficient — a static review that "looks right" is still vibe
   coding. Execute it: run the tests, launch the app, hit the real API/endpoints, and
   check each acceptance criterion against observed behavior. Verify external
   assumptions empirically (e.g. does the API actually accept that input?) rather than
   trusting the spec's claims. If you cannot run it, say so explicitly — do not mark
   the gate passed.
3. **Trajectory check** — did it take a sane path? (Limit: print mode returns only the
   final text. The per-conversation logs under `~/.gemini/antigravity-cli/conversations`
   are **SQLite `.db` files with opaque blob columns, not human-readable** — don't rely
   on reading them. Instead, have agy **summarize its own steps** as part of its output,
   or keep a session with `--continue`/`--conversation` and ask it to recap.)
4. **Review every shipping line** — be skeptical of clever code; check imports are real
   packages (hallucinated deps), error handling, edge cases, and that the contract
   itself is internally consistent (examples/placeholders match the verified behavior).
5. **Never trust agy's "GREEN" — re-run the gate yourself in a clean state.** Measured:
   agy will, to make a check pass, **modify the environment itself** — e.g. patch the
   installed package in site-packages, or `MagicMock`-stub a missing dependency — and then
   report success. Before believing a passing test/eval: diff any touched tooling against a
   pristine reference, restore it, and re-run the gate under Claude's own control. agy's
   self-reported pass is a claim, not evidence.
If wrong: retry on `--tier pro`, sharpen the spec, or do that piece yourself.

## Safety for write tasks

Read-only work (search, review, analysis) is low-risk. **When agy writes files or runs
commands** (`--yolo` grants write + terminal):
- Run it on a **dedicated git branch or worktree** so changes are isolated.
- Add `--sandbox` for execution containment.
- **Claude reviews the diff before merging** — never auto-merge agy's writes.

## Cost discipline — where the savings actually come from

Delegation does **not** save money by itself. Measured reality: on a small task the
hybrid cost *more* than Claude-only, because the dominant cost was Claude's own
`cache_read` — re-reading a large, growing context across many orchestration turns.
The savings the "Gemini sub-agent" concept promises are real, but only when you keep
Claude's context lean and the round-trips few. Apply these as hard rules:

1. **Delegate above the break-even, not below.** Hand work to agy only when the offloaded
   volume **clearly exceeds** the spec-writing + round-trip + verification overhead it
   adds. Bulk/parallel/repetitive (mass migration, exhaustive tests, fan-out research,
   long-context reads that return a small digest) = delegate. Small, self-contained, or
   judgement-heavy = just do it yourself. (Delegating a tiny task is a *net loss*.)
2. **Keep Claude's context lean (the biggest lever).** Do **not** pull the files agy
   already handled (`--dir`) back into Claude's context, and do **not** paste agy's raw
   bulky output into the thread. Claude ingests a **digest**, not raw content — this is
   what collapses the per-turn `cache_read` that made the hybrid expensive.
3. **Make agy return a digest, not a dump.** End every delegation prompt with an explicit
   trailer instruction, e.g.:
   `"...End with a fenced block ===DIGEST=== listing: files changed, key decisions, and a 1-paragraph 'context for next step'. Put bulky detail ONLY in files, not in your reply."`
   Claude reads the DIGEST; the bulky work stays on cheap Gemini tokens.
4. **Batch, don't chatter.** One large, fully-specified delegation beats many small
   round-trips (each round-trip re-reads context = `cache_read` tax).
5. **Review the diff, not the whole tree.** `git diff` is compact; reading every file is
   not.
6. **Hold state on the cheap side.** For multi-step jobs, keep an agy session with
   `--continue` / `--conversation <id>` so the working context lives in Gemini, and Claude
   passes deltas instead of re-supplying everything.
7. **Asymmetric effort.** The conductor doesn't need max reasoning effort to coordinate +
   verify; run Claude at a moderate effort and let the cheap workers do the volume.
8. **Don't fight the prompt-cache TTL on small tasks (measured trap).** The 5-min cache
   expires while you wait on a long agy delegation, so the next turn pays `cache_create`
   (1.25× input) instead of `cache_read` (0.1×). It's tempting to "keep the cache warm"
   with busy turns — **measured: that backfires**, because every warming turn generates
   frontier `output` (5× input), the most expensive class, and net cost goes *up*. Do NOT
   manufacture work to stay warm. Backgrounding a long delegation (Bash `run_in_background`)
   is fine to avoid *blocking*, but it does not make a small task cheaper. The only real
   fix is **scale**: make each delegation big enough that the displaced Claude output
   dwarfs the one-time re-cache cost. Below the break-even, the hybrid loses on cost — three
   optimization variants were tested on a small task and none beat solo Claude (see
   `docs/AB-RESULTS.md`). Delegate for cost reasons only at scale.

Honest framing for any cost claim: there is **no flat 8×/46%**. Below the break-even the
hybrid costs more; above it, lean-context routing cuts frontier-model spend by a
*measured* margin. Quote the measured number and the break-even, never a headline ratio.
Use `agy-cost-compare.sh` for the per-token gap (estimate; set real Vertex rates first).

## SDLC recipes

```bash
ROOT="$CLAUDE_PLUGIN_ROOT/scripts/agy-delegate.sh"

# Scaffold from a spec (Claude wrote the spec/architecture)
"$ROOT" --tier pro --yolo --sandbox --dir ./app \
  "Scaffold per ARCHITECTURE.md: dirs, configs, stub modules. Follow AGENTS.md."

# Generate tests for a contract Claude defined
"$ROOT" --tier flash --yolo --dir ./app \
  "Write unit + edge-case tests for src/payments.py covering the cases in SPEC.md."

# First-pass review (Claude does the final pass)
"$ROOT" --tier pro "Review for bugs/security/perf, be skeptical. List file:line: <diff>"

# Implement-until-tests-pass (feedback loop; isolate on a branch)
"$ROOT" --tier pro --yolo --sandbox --dir ./app \
  "Implement feature X to satisfy AGENTS.md and make 'pytest -q' pass. Iterate until green."

# Migration / modernization
"$ROOT" --tier pro --yolo --sandbox --dir ./svc \
  "Migrate all callers from APIv1 to APIv2 per MIGRATION.md. List every file changed."

# Web search → Claude re-checks
"$ROOT" --tier pro --yolo "Use web search for <X>. Give URLs + dates."

# Vertex AI Search over internal data (discover engines, then query)
"$ROOT" --tier pro --yolo "List Vertex AI Search engines (list_engines)."
"$ROOT" --tier pro --yolo "Search engine <ENGINE_ID> for: <question>. Cite the hits."
```

## Deep-research recipe (multi-source)

agy has **no built-in "Deep Research" mode** — that product lives in the Gemini app
and the Gemini API's managed Deep Research Agent, **not the CLI** (verified). But agy
*can* do genuine multi-step, cited web research via its agentic loop. So deep research
is a **Claude-orchestrated recipe**, not a single agy call. Pair it with Claude's own
`deep-research` skill as planner/verifier; agy is the cheap, grounded legwork worker.

Caveat that shapes the recipe (verified empirically): in `--print` mode agy uses
search-**summary** tools and does NOT reliably fetch full pages, so its citations are
coarse (often domain-level) and may not actually support the claim. It can also leak
parametric "knowledge" disguised as a sourced fact. **Never ship its citations
unverified.**

1. **Plan (Claude).** Decompose into sub-questions + an explicit list of load-bearing
   claims to verify. Claude owns scope and final synthesis.
2. **Fan-out fetch (agy, cheap, parallel).** One call per sub-question; force compact
   stdout so bulky pages stay in Gemini's context, not Claude's:
   ```bash
   "$ROOT" --tier flash --yolo \
     "Use web search for <sub-question>. Return 5-8 bullet findings, each with the
      exact source URL and publication date. Output ONLY findings+URLs+dates."
   ```
3. **Deepen on key sources (agy).** For each load-bearing claim, name the URL and make
   agy quote the supporting text (turns domain-level citations into verifiable quotes):
   ```bash
   "$ROOT" --tier pro --yolo \
     "Open <URL> and quote the exact sentence(s) supporting: '<claim>'.
      If the page does not support it, reply NOT SUPPORTED."
   ```
4. **Adversarial verify (Claude).** Corroborate each key claim across ≥2 independent
   domains; treat any single/vague/domain-only citation as unverified; sanity-check
   dates; watch for Gemini parametric knowledge masquerading as a sourced fact.
5. **Synthesize (Claude).** Write the final cited report from verified findings only;
   mark anything uncorroborated as "unverified."

Iteration is Claude's job: `--print` does one agentic pass per call (no auto re-query
when evidence is thin), so Claude must re-dispatch follow-up agy calls to close gaps.
Token economics: bulky searched/fetched text is paid in cheap Gemini tokens and
distilled to bullets+URLs before reaching Claude — use `agy-cost-compare.sh` to show it.

## What Antigravity brings that Claude lacks natively

Built-in Google tools (MCP), verified working in headless `--print` mode:
- **Google / web search** — current, grounded info.
- **Vertex AI Search** — search internal/company data stores (`list_engines`,
  `search`, `conversational_search`).
- **Google Cloud Logging**, **Notebooks** (Colab/Jupyter), **Visualization** (charts).

Tool use in headless mode requires `--yolo` (print mode can't show approval prompts);
search/list tools are read-only so this is low-risk.

## Economics (a financial lever, not the headline)

Routing deterministic, high-volume work to Gemini Flash (≪ Claude per token) is
**intelligent model routing**: higher CapEx (this harness) for lower OpEx (cheap model
does the bulk). Use the cost demo as observability:
```bash
"$CLAUDE_PLUGIN_ROOT/scripts/agy-cost-compare.sh" --tier flash "the task prompt"
```
Estimates only (chars/4; agy exposes no token API in print mode). Set real Vertex rates
via `CLAUDE_IN_PER_M`, `CLAUDE_OUT_PER_M`, `GEMINI_IN_PER_M`, `GEMINI_OUT_PER_M`.

## Prerequisites & limits

- `agy` installed and authenticated (`agy models` lists Gemini models); its
  `~/.gemini/antigravity-cli/settings.json` points at a GCP project/region.
- Scripts executable (`chmod +x scripts/*.sh`).
- agy v1.0.x: `-p` takes the prompt as its value (wrapper handles); no JSON output;
  print mode returns final text only (no trajectory); no `timeout(1)` on macOS (use
  `--timeout`).
