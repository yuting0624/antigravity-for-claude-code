---
name: antigravity
description: Run the Antigravity CLI (Gemini) as a collaborating AI inside Claude Code, with intelligent model routing across the software development lifecycle. Claude is the conductor/orchestrator — requirements, architecture, the hard 20%, verification, and review — and routes deterministic, high-volume work (scaffolding, boilerplate, test generation, first-pass review, migrations, web/Vertex AI Search) to Antigravity (Gemini), the cheaper, faster model. Use when the user wants to "use Antigravity / agy", "vibe code / agentic engineering", "accelerate the SDLC", "delegate to Gemini", "scaffold / generate tests / migrate", "first-pass code review", "search web or internal/company data", "deep research / multi-source research report", "second-model cross-check", or "lower token cost on a big job". Claude always verifies Antigravity's output and re-checks itself if unsatisfied.
version: 0.22.4
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
| Audio / video understanding | **agy** transcribes + digests · **Claude** verifies | Gemini is natively multimodal; no local ffmpeg/speech stack |
| Deep research (multi-source) | **agy** fans out search/fetch · **Claude** plans, verifies ≥2 sources, synthesizes | offload bulky pages to cheap Gemini; frontier model judges |

Routing tier within agy: `flash` (default, bulk) · `flash-lo` (cheapest, trivial) ·
`pro` (harder reasoning / reviews / cross-checks).

**agy is multi-model.** Tiers map to Gemini by default, but you can point delegation at any
model `agy models` lists (Claude / GPT on plans that expose them) — via `--model <exact name>`,
or persistently with the `default_model` / `tier_*` plugin options. Keep the executor a
*different, cheaper* model than the Claude conductor: that's what yields the cost saving **and**
the cross-model verification value (Claude executing Claude loses both).

> **Model availability moves fast, and `--tier` needs agy ≥ 1.1.10.** Until 1.1.10, agy
> **ignored `--model` and `--effort` in headless `-p`** — the flag was applied after model
> configuration had initialised, so the run silently fell back to the persisted default.
> This wrapper resolves every `--tier` to `--model` and always runs `-p`, so on an older
> agy **tier selection does nothing and looks like it works**: the call succeeds, returns
> sensible text, reports usage. `doctor` warns when it sees one.
>
> The `flash` default is **Gemini 3.5 Flash (High)**, for broad plan availability — newer
> models can lag on enterprise Vertex. Gemini 3.6 Flash is available and its **output is
> cheaper ($7.50/M vs $9.00/M; input and cached-input unchanged — confirmed against two
> pricing sources)**, so remapping `tier_flash` to `gemini-3.6-flash-high` is reasonable
> when your plan serves it. Price it with `prices.json`'s `gemini_flash_36`;
> `agy-cost-compare` picks the `gemini_flash` key by tier name, not by model.
>
> **Retracted:** earlier versions of this note quoted token-level comparisons between
> 3.5 / 3.6 / `flash-medium` (−23% input, `cache_read` +43%, and so on). Those runs were
> made on agy 1.1.8–1.1.9, where `--model` was ignored — so every arm may have executed
> the same persisted default. Independently, the numbers did not survive their own ranges:
> 3.5-high spanned [421k, 509k] input against 3.6-high's [305k, 412k] at n=2, and
> `flash-medium` overlapped `high` outright. A mean-vs-mean claim over overlapping ranges
> is exactly what this repo's own playbook tells you not to report. Pick a tier by what
> your plan serves and by the published rates until this is re-measured on 1.1.10+.
>
> Note: agy 1.1.5 changed `agy models` output to slugs (`gemini-3.5-flash`); both slugs and
> display names are accepted by `--model`, and `doctor` matches either.

## How to call it

```bash
agy-delegate [options] "the task prompt"
```
Options: `--tier flash|flash-lo|pro` · `--dir <path>` (workspace, repeatable) ·
`--timeout 10m` · `--yolo` (auto-approve **ALL** tools — the blunt grant; needed for web /
Vertex AI Search / terminal, and for writes not covered by a `permissions.allow` rule. For a
file write the narrower grant is usually a `write_file(<dir>)` entry in
`~/.gemini/antigravity-cli/settings.json`, which needs no flag — see below. Run write tasks
on a branch) · `--mode accept-edits|plan`
(agy execution mode: `accept-edits` auto-applied file edits headless on 1.1.0–1.1.2 but is
**soft-denied on 1.1.3** — no longer a dependable headless write grant;
`plan` = strategize only) · `--sandbox` ·
`--digest` (append a digest-only output contract — use it for any
bulk read/analysis; the wrapper also warns on stderr when a reply comes back dump-sized,
because ingesting digests instead of dumps is the single biggest cost lever) ·
`--print-command` (dry run: show the resolved `agy` call, don't run it) · pipe a long
prompt with a trailing `-`.

The wrapper handles agy's quirks (prompt is the value of `-p`; non-TTY stdout drop via
`< /dev/null`). On **agy ≥ 1.1.8** it also runs agy with `--output-format json`
internally: **stdout still gives you the model's text unchanged**, but failures are
classified from the structured `error` instead of scraped prose, and the executor's real
token usage (input / output / thinking / **cache_read**) is reported as an `AGY_USAGE
{...}` line on stderr — so the Gemini side of a delegation can finally be *measured*, not
estimated. Older agy (or no `python3`) transparently falls back to the plain-text path;
force it with the `structured_output` option.

> **Accounting semantics for `AGY_USAGE` (verified — get this wrong and your cost math
> is wrong).** `total = input + output` (and `thinking` is *inside* `output`).
> **`cache_read` is a separate counter: it is NOT part of `total`, and it is not a subset
> of `input`** — in an agentic delegation it routinely *exceeds* `input` (measured:
> `cache_read` 1,356,694 vs `input` 243,117 in one delegation). So price the Gemini side
> as `input×in_rate + output×out_rate + cache_read×cached_rate`, three separate terms.
> This differs from the Claude/Harbor side, where cache-read tokens *are* an inner subset
> of the reported input total — don't carry one convention over to the other.
>
> **If you are measuring, set `AGY_USAGE_LOG=/path/to/log`** (or the `usage_log` option).
> `AGY_USAGE` and `AGY_SIGNAL` go to stderr, and the advice two paragraphs down — keep
> Claude's context lean — makes `agy-delegate ... 2>&1 | tail -N` the natural thing to
> write. stdout (the digest) is emitted *after* the usage line, so `tail` keeps the digest
> and silently drops the usage. Measured in the wild: a benchmark harness lost most of its
> Gemini-side data exactly this way, which made the hybrid look cheaper than it was. A
> named file cannot be truncated by a pipe.

**Two ways to delegate.** Call the wrapper directly (above), or — when you want file
generation to happen entirely on Gemini with **zero Claude tokens spent writing** — hand
the unit to the **`antigravity-delegate` subagent** (its only file-acting tool is the
wrapper; it returns a digest for you to verify). Either way, *you* still own verification.

**Structured failures.** The wrapper exits `10` quota · `11` auth · `12` timeout · `13`
agy-missing · `14` model-unavailable (a `--model` / `tier_*` / `default_model` name not in
`agy models` — agy ≥ 1.1.2 hard-fails instead of silently downgrading) · `15`
permission-denied (agy ≥ 1.1.3 soft-denies a permissioned tool headless — pass `--yolo`)
(besides `2` failed / `3` empty). On agy ≥ 1.1.8 these are derived from the structured
`status`/`error` envelope rather than stderr pattern-matching, so the classification is
reliable. It prints a `AGY_SIGNAL {...}` line on stderr;
`agy-job status`/`result` surface it, so you can react (e.g. retry quota with `--continue`,
fix the model name, or add `--yolo`) instead of scraping prose.

**If Claude itself is running headless (`claude -p`, one-shot):** run delegations
**synchronously** — let `agy-delegate` BLOCK and return before you continue. Do NOT
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
   or keep a session with `--continue`/`--conversation` and ask it to recap.
   **But every run leaves a readable trajectory:** `transcript.jsonl` under
   `~/.gemini/antigravity-cli/brain/<conversationId>/` — for plain delegations too, not
   just internal-fan-out subagents. `agy-delegate` prints the `conversationId` in its
   `AGY_USAGE` line, so cost and trajectory join 1:1. Audit with
   **`agy-trace --audit <conversationId>`** (or `--audit --last`): step-type counts plus
   every non-zero exit. A delegation can report SUCCESS while commands inside it failed —
   measured: 6 failed commands inside one overall-"SUCCESS" run. `agy-trace <id>` prints
   the full steps; `--list` finds recent ones.
   **What is NOT recorded: the command strings.** Not in `transcript.jsonl`, not in
   `transcript_full.jsonl`, not in `~/.gemini/antigravity-cli/log/cli-*.log`. You get
   *that* a command ran, its exit code and its output. To attribute a filesystem change,
   diff the tree — the trajectory cannot tell you.)
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
- **Write tasks need a grant — and it does not have to be `--yolo`.** Headless agy's no-permission behavior has shifted
  every few releases — describe-only (pre-1.1.0), scratch-divert (1.1.0–1.1.2), soft-deny
  with a stderr notice (1.1.3) — but in every version **your workspace stays untouched
  while the run still "succeeds"** (issue #10). **Two things grant a write, and `--yolo` is
  the blunt one.** A `write_file(<dir>)` entry under `permissions.allow` in
  `~/.gemini/antigravity-cli/settings.json` allows writes **recursively beneath `<dir>`**
  with no flag at all — confirmed on agy 1.1.9 by a controlled A/B (#37): covered target
  wrote, uncovered target returned `PERMISSION_DENIED`, rule the only variable. agy's own
  denial text names the rule and offers `--yolo` as the *alternative*. `--yolo` auto-approves
  **all** tools and is what you need when no rule covers the target, or for web / Vertex AI
  Search / terminal. Not verified below 1.1.9; a glob form (`write_file(/path/**)`) was
  reported not to match. Run write tasks on a branch and verify with `git status`.
  prompt for or block `--dangerously-skip-permissions` — approve it or pre-allow
  `Bash(agy-delegate*)`. Always verify files actually changed **in the workspace** with
  `git status` (the wrapper maps a 1.1.3 soft-deny to exit `15` so you're not left guessing).
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
6. **Do not hold state on the executor to save money — measured, it costs more.** It is
   tempting to keep one agy session alive with `--continue` / `--conversation <id>` so the
   working context "lives on the cheap side". It does not work: resuming carries the whole
   prior conversation forward *and* agy re-reads the material anyway, and agy's prompt
   cache covers only ~2/3 of its context re-reads. Measured on a repeated-corpus digest,
   the continued call cost **+82% / +277%** vs a fresh one (n=2). Use `--continue` for what
   it is good at — **resuming after a quota or timeout failure** — and get multi-step
   savings from rule 4 instead (one large delegation, not many small ones).
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
Use `agy-cost-compare` for the per-token gap (estimate; set real Vertex rates first).

### The number of delegations is the lever — batch them (measured)

Rule 4 above ("batch, don't chatter") is the one that actually moves the needle, and
here is why, from a benchmark of this plugin
(Opus 5 conductor · Gemini 3.6 Flash High executor · agy 1.1.8 · n=3/arm, cold cache):

**Per delegation the economics are fine. Repeated ingestion is what breaks them.**
Offloading a large corpus works exactly as designed — the conductor's `cache_read` fell
**61%**, it never opened the corpus itself, and each digest came back at ~4k tokens. But
**each `agy-delegate` call is an independent session that shares no cache with the last
one**, so a conductor that delegated 7.3 times against the same corpus paid to ingest it
7.3 times. **Two-thirds of the executor's cost was re-reading material it had already
read.** Break-even on that task was ~5.7 delegations; the one trial that stayed at 5 came
in cheaper than solo Claude, the ones at 9 did not.

So when several delegations work over the same material:

- **Fold related units into ONE fully-specified delegation.** This is the only lever that
  actually removes a re-ingestion. Two questions about one corpus = one delegation asking
  for both, not two delegations.
  **Only fold units that genuinely belong together.** If combining them muddies the spec,
  don't — a vague mega-prompt returns worse work, and re-running it costs far more than
  the re-ingestion you saved. Quality of the spec beats the token arithmetic every time.
- Scope `--dir` to the smallest subtree that contains the work, and expect the executor's
  **read** cost — not its writing — to dominate.
- **Do NOT reach for `--continue` to avoid re-ingestion — measured, it makes things
  worse.** Resuming a session carries the whole prior conversation forward *and* agy
  re-reads the material anyway, so you pay both: on a repeated-corpus digest the continued
  second call cost **+82% and +277%** vs a fresh one (n=2), with `cache_read` 3–14× higher.
  `--continue` is for *resuming after a failure* (quota, timeout) — not a cost lever.

Two supporting facts, both measured: **delegation moves work rather than removing it**
(the hybrid ran ~2.8× the normalized token volume for the same result — it stays
affordable because the executor is cheaper per token, not because it does less), and
**agy's own prompt cache covers only ~2/3 of its context re-reads**, so the executor is
worse than Claude at carrying context. Both push the same way: fewer, larger, session-
reusing delegations.

These are single-configuration measurements from 2026-07 on two task families, not
constants. Treat them as direction, and re-measure on your own workload before quoting
any figure.

## SDLC recipes

```bash
ROOT=agy-delegate

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

# Audio / video / image understanding (Claude can't hear or watch; Gemini can)
# agy-media writes the full transcript to a FILE and returns a timestamped digest —
# never ingest a whole transcript (a 1-hour recording is ~10k words of cache_read).
agy-media ./meeting.wav "decisions and owners"     # digest -> you; transcript -> ./meeting.transcript.md
agy-media ./demo.mp4 --timeout 20m                 # video: adds timestamped VISUALS/OCR
agy-media ./memo.m4a --convert                     # agy mishandles m4a/aiff; converts to wav first
# Verify before relying on it: the digest flags unclear audio + uncertain names/numbers —
# grep that timestamp out of the transcript file rather than trusting the summary.

# Vertex AI Search over internal data (discover engines, then query)
"$ROOT" --tier pro --yolo "List Vertex AI Search engines (list_engines)."
"$ROOT" --tier pro --yolo "Search engine <ENGINE_ID> for: <question>. Cite the hits."
```

## Internal fan-out recipe (agy spawns its own subagents)

agy has built-in `define_subagent` / `invoke_subagent` tools. Which pattern works is
**version-dependent** — this surface is moving fast upstream (4 releases in one week
while we tracked it), so re-verify after any agy upgrade:

- **agy ≥ 1.0.16 — dynamic custom subagents (preferred):** have agy `define_subagent` a
  named specialist in-session (name / description / system_prompt), then
  `invoke_subagent` it by that TypeName. **Verified headless on 1.0.16 and re-verified
  on 1.1.0**: define → invoke → result round-trips cleanly, real thread spawned.
  (1.0.13–1.0.15 shipped this broken — defined agents failed to invoke, upstream #521;
  fixed in 1.0.16. Subagents are officially documented as of 1.1.0 —
  antigravity.google/docs/cli/subagents — with static config at
  `<workspace>/.agents/agents/*.md` and global `~/.gemini/config/agents/`.)
- **Any version — role delegation (fallback):** the sandbox pre-approves TypeNames
  **`self`** and **`research`**; an *undefined* custom TypeName is rejected with
  `CORTEX_STEP_TYPE_INVOKE_SUBAGENT: ... not found or not allowed to be invoked`
  (upstream #105). Invoke TypeName `self` and inject the specialty via `Role` +
  `Prompt` — verified on 1.0.12 **and re-verified on 1.0.16**.

Use it for **orchestrator-mode work pushed down a level**: instead of Claude dispatching
N parallel `agy-job` runs (N round-trips, coordination spend on the frontier side), send
ONE delegation and let agy fan out internally — the coordination tokens land on the
cheap side, and you ingest a single digest.

```bash
# Preferred form (agy >= 1.0.16). --yolo is required so the subagent tools aren't
# soft-denied headless (see below). Verified live on agy 1.1.5.
agy-delegate --dir . --yolo --digest --timeout 10m \
  "ACTUALLY use your define_subagent and invoke_subagent tools (do NOT simulate).
   Decompose <task> into up to 3 units. For each unit: define_subagent a named specialist
   (name + system_prompt for its role, following this repo's conventions / AGENTS.md if
   present), then invoke_subagent it by TypeName with the unit's work. Wait for ALL, then
   report per-unit results, EACH subagent's conversationId, and end with a DIGEST line."
# Any-version fallback: replace define/invoke with TypeName "self" + a specialist Role.
```

Verified behaviors (1.0.12 → 1.1.5):
- **Pass `--yolo`.** On 1.1.3+ the subagent tools need permission that headless mode
  can't prompt for, so without `--yolo` the spawn is soft-denied (wrapper exit 15).
  (On 1.0.x spawning was ungated, but `--yolo` is the durable choice here: a
  `permissions.allow` `write_file(...)` rule covers file writes only, not
  `define_subagent`/`invoke_subagent`, and not web / Vertex AI Search.)
- Each spawn's tool result includes a `logAbsoluteUri` → a **readable step-by-step
  `transcript.jsonl`** under `~/.gemini/antigravity-cli/brain/<conversationId>/` —
  *better* trajectory visibility than a plain delegation. Location unchanged across
  1.0.12→1.1.5, for both `define_subagent` and `self` spawns. Have the parent report
  each `conversationId`, then audit with `agy-trace <id>` (`agy-trace --list` finds
  recent ones). Note: the parent may also create a coordination thread of its own, so
  `--list` can show one more conversation than the units you asked for.
- Spawns are real and observable (new conversation threads appear) — but still run the
  verification gates on the merged result; more autonomy = more surface for error.

Caveats: neither pattern is a documented contract yet — `self`+Role works around the
sandbox allowlist, and even the official docs' static agent-config paths don't match
observed behavior (upstream #527) — so **re-verify after agy upgrades** (1.0.16 changed
this area within a day of our first verification). Bound the fan-out width in the
prompt (agy chooses parallelism otherwise). A wide fan-out takes longer wall-clock —
raise `--timeout`, and in an interactive session prefer a background job (`agy-job`).

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
distilled to bullets+URLs before reaching Claude — use `agy-cost-compare` to show it.

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
agy-cost-compare --tier flash "the task prompt"
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
- **WSL:** `--add-dir` on a Windows mount (`/mnt/c/...`) reads over a slow 9p bridge —
  calls can take 20s+. Keep the repo on the Linux filesystem (`~`); the wrapper warns.
