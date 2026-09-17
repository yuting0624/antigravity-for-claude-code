---
name: antigravity
description: Delegate the READING to a long-context model and keep the judgement on Claude. Through the `delegation` MCP server this plugin ships, Claude digests a codebase (`digest_codebase`), runs read-only tasks over files (`delegate_task`), gets an independent second review of a diff from a different model family (`review_diff`), and reads recordings, video, images and long documents (`digest`) — the files never enter Claude's context, only a digest with file:line references does. Use when the user wants to "understand / map / trace this codebase", "find every place that …", "summarise this change / these files / this recording", "second-model cross-check / independent review", "delegate to Gemini", "read this without blowing up my context", "lower token cost on a big read", or asks a question whose evidence is spread across many files. Claude always verifies the digest and owns correctness.
version: 1.0.0
---

# Antigravity for Claude Code — delegate the reading, keep the judgement

Claude Code is the **conductor**: requirements, design, the hard 20%, verification,
review. The `delegation` MCP server this plugin ships is the **reader**: a long-context
model that takes a selection of files and returns a compact digest with `file:line`
references. The verb is *ingest*, not *execute* — and that is a measured choice.

- **Delegating execution did not pay.** Handing writes and agentic loops to a cheaper
  model moved work rather than removing it (~2.8× the token volume for the same result),
  needed grants, and had to be re-verified against the filesystem anyway.
- **Delegating reading pays every turn.** A 62k-token corpus offloaded to a digest left
  the conductor carrying 4.4k tokens instead of 62k on every later turn; on this plugin's
  own source, a 173k-token selection came back as a 1.5k-token digest in five seconds
  with every reference resolving to a real line. What Claude never reads, Claude never
  re-reads.

So: **the server never writes.** Writing, running, and judging stay with Claude.

*Generation is solved; verification, judgement, and direction are the craft.*

## Two modes (pick per task)

- **Inline (sync):** you are shaping something now; digest the relevant part of the
  tree, read the references it points at, continue. Most calls.
- **Background (async):** a very large selection, or a read you do not need before your
  next step — `async: true` returns a job id; `job_status` / `job_result` collect it.
  Only in an interactive session: headless `claude -p` has no later turn.

## Division of labor

| Phase | Owner | Why |
|---|---|---|
| Requirements, design, architecture | **Claude** | ambiguity, trade-offs |
| Orientation in an unfamiliar codebase | **server** reads → **Claude** navigates by reference | the bulk stays out of context |
| Tracing data flow, "where is X", questions spread over many files | **server** (`digest_codebase`) → **Claude** verifies the references | long context is cheap there, expensive here |
| Inventories, extractions, comparisons, migration lists | **server** (`delegate_task`) → **Claude** checks against a grep | mechanical, high volume, read-only |
| Implementation, edits, running the gate | **Claude** | correctness, and the server cannot write |
| Second review of a change | **server** (`review_diff`, a different model family) → **Claude** reconciles | two families ≠ same blind spot |
| Recordings, video, images, long PDFs | **server** (`digest`) → **Claude** verifies load-bearing claims | natively multimodal there |
| Cloud Run error logs | `/antigravity:cloud-run-debug` → **Claude** infers the fix | logs digested on the cheap side |
| Web research | **server** (`search_web`, Google Search grounding) fans out · **Claude** plans, verifies ≥2 sources, synthesises | bulky pages stay on the cheap side; the frontier model judges |

**Who decides the model.** Tools name a logical alias — `ingest` (long context, low
thinking), `review` (a different family from the conductor), `cheap` (condense passes) —
never a model. The alias table is configuration the organisation controls: on the
default `vertex` driver it maps to Gemini on Vertex AI, and an alias written
`anthropic/<model>` is served by Claude on Vertex AI through the same project and proxy
(the way `review` stays a different family when the author is Gemini); behind an
organisation gateway the gateway resolves it. Requests leave the machine only to hosts on the server's
**egress allowlist** (`*.googleapis.com` by default); everything else needs an entry the
organisation adds. `/antigravity:setup` shows both.

## How to call it

The server's tools appear as MCP tools; the subagent and the commands use them. Always
pass `root` (the repository directory) and the narrowest `paths` that contain the answer.

| Tool | Use | Key arguments |
|---|---|---|
| `digest_codebase` | a question about the code, or a general digest for orientation | `paths`, `root`, `question?`, `token_budget?` (default 4000), `cache?`, `async?`, `batch?` |
| `delegate_task` | a deliverable: inventory, extraction, comparison, summary with a defined shape | `spec`, `paths?` (omit for a text-only task), `root`, `token_budget?`, `async?`, `batch?` |
| `review_diff` | an independent second read of a change | `range?` (e.g. `HEAD~1`, `main...HEAD`), `paths?`, `diff?`, `rubric?`, `adversarial?` |
| `digest` | recordings, video, images, PDFs, long documents | `file_paths`, `question?`, `focus?`, `tier?`, `save_transcript?` |
| `search_web` | grounded web research: dated, URL-cited findings and the sources used (vertex driver only) | `query`, `question?`, `token_budget?` |
| `job_status` / `job_result` / `job_cancel` | background jobs | `job_id?`, `all?` |
| `health_check` · `savings_report` | diagnostics; what has been kept out of context over time | — |

What comes back, always in the same shape: notes (redactions, skips, cache, truncation)
→ the digest (markdown: summary, findings with `file:line`, references, open questions,
for tasks a **Verify this** list) → a stats line → a small JSON block with `stats` and
`usage` → the `usage:` / `offload:` footer → `endpoint: geap|external (host)`.

**Two ways to delegate.** Call the tools yourself, or hand the unit to the
**`antigravity-delegate` subagent** — its only tools are the server's, so the bulky
read *cannot* land in its context either; it returns the digest plus a VERIFY THIS line.
Either way, *you* own verification.

**Structured failures.** A failed call ends with `error: {"code":N,"kind":"…","retry":bool,…}`:
`10` QUOTA (retry later) · `11` AUTH (`/antigravity:setup`) · `12` TIMEOUT (narrow the
selection or go `async`) · `14` MODEL (the alias is not served; `/antigravity:setup`) ·
`15` PERMISSION (root outside the allowed roots, or a destination host outside the egress
allowlist — `host` is named; neither is yours to change) · `1` INPUT · `2` UNKNOWN.

**If Claude itself is running headless (`claude -p`, one-shot):** call synchronously.
Do NOT pass `async` expecting a later turn — there is none.

## Verification gates (non-negotiable)

Claude owns correctness. A digest is a **claim**, not evidence.

1. **Define the contract first** — for anything you will build from a digest, write the
   test or the acceptance criterion before you act on it.
2. **Read `stats.refs_valid_ratio`, then open the references.** The server checks that
   every `file:line` points at a real line in the selection (for a review, at a line
   shown in the diff) — not that the claim about that line is true. Below about 0.9,
   treat the digest as unreliable and narrow the question. Open the references behind
   anything load-bearing.
3. **Run it, don't read it.** Reading a diff that "looks right" is still vibe coding.
   Execute: tests, the app, the real endpoint. If you cannot run it, say so and do not
   mark the gate passed.
4. **Review every shipping line** — hallucinated imports, error handling, edge cases,
   internal consistency of the contract itself.
5. **Never trust a self-reported GREEN** — from any model, including a review's
   `approve`. Re-run the gate under your own control in a clean state.
6. **Cross-model review is the second pair of eyes, not the judge.** `review_diff` with
   the `review` alias reads with a different family from yours; agreement across two
   families is a stronger signal, disagreement is a prompt to look closer, and you
   reconcile. Measured on this plugin's own code: the first live review found four real
   defects the author had shipped an hour earlier. Two independent scans insure against
   *one model's* blind spot — not against a gap in what you handed both of them.

If wrong: sharpen the question, narrow `paths`, ask with `alias: "review"`, or read that
piece yourself.

## Safety: what leaves the machine, and what never does

- **The server only reads.** No tool writes, edits or executes anything in your tree.
  `digest` may write a transcript file only when you ask (`save_transcript`).
- **Only under `root`.** Nothing outside the selection root (and, when set, the
  organisation's allowed roots) is read; symlinks that escape are skipped.
- **What is sent:** the selected files' text after `.gitignore`, a built-in ignore list
  (secrets, lockfiles, build output), binary and media detection, and redaction of
  credential-shaped strings (`[REDACTED:kind#n]`; pattern-based, so treat it as a net, not
  a guarantee). The footer names the destination host on every call.
- **What comes back is bounded by construction:** a schema with no field for content, a
  token budget with a condense pass behind it, hard caps on every string and array, a
  detector that elides runs of source reproduced verbatim, and no MCP resource that
  exposes files. The `stats` line reports every guard that fired.
- **Batch jobs** stage the (redacted) selection as JSONL in your project's Cloud Storage
  bucket for the life of the job and delete it afterwards.

## Cost discipline — where the savings actually come from

Delegation does **not** save money by itself. The dominant cost in a long session is
Claude re-reading its own growing context on every turn; a digest is cheaper than a
corpus only if the corpus never enters. Hard rules:

1. **Delegate above the break-even.** Three files or more, or roughly 20k tokens or more
   → digest first, then read only the references. Under about 6k tokens the round-trip
   costs more than it saves. Small, self-contained, judgement-heavy → do it yourself.
2. **Ingest the digest, never the corpus.** Do not open the files the server already
   read except the specific references you must verify. This is the lever: it is what
   collapses per-turn `cache_read`.
3. **One call per selection.** Two questions about the same files = one call asking
   both. Every call re-reads the selection; the server creates a context cache on the
   second request for the same selection within an hour (`cache: "on"` to create it up
   front when you know you will ask more than once), and a cached call costs about a
   tenth of an inline one — but one call is still cheaper than two.
4. **Keep `token_budget` honest.** The default 4000 is what you will carry on every later
   turn; ask for 1500 when the question is narrow.
5. **Review the diff, not the tree.** `review_diff` on a range is compact; digesting the
   whole repository to review one change is not.
6. **Batch, don't chatter.** Fold related units into one fully specified call — but only
   units that genuinely belong together; a vague mega-prompt returns worse work and
   re-running it costs more than the re-read you saved.
7. **Asymmetric effort.** The conductor does not need maximum reasoning effort to
   coordinate and verify.
8. **Don't manufacture work to keep the prompt cache warm.** Every warming turn produces
   frontier output tokens, the most expensive class; measured, it backfires. Backgrounding
   a long read (`async`) is fine to avoid *blocking*; it does not make a small task cheaper.

Honest framing for any cost claim: there is **no flat ratio**. Below the break-even the
hybrid costs more; above it, lean-context routing cuts frontier spend by a *measured*
margin. Quote the measured number and the break-even. `savings_report` totals what the
server has kept out of context; `measure-session.py --join` puts the Claude side and the
delegation side of one session on the same screen.

## Recipes

```text
# Orientation in a service you have not read
digest_codebase({ paths: ["services/billing"], root: "<repo>",
                  question: "How does a request get authenticated, and what happens on failure?" })
→ read summary + findings; open only the 2–3 file:line references that matter.

# Inventory across the tree (a deliverable, not a question)
delegate_task({ spec: "List every environment variable read, grouped by module, with file:line, and flag any not documented in README.md",
                paths: ["src", "README.md"], root: "<repo>", token_budget: 2500 })
→ verify: grep -rn 'process.env' src/ and compare counts before relying on it.

# Second review before merging
review_diff({ root: "<repo>", range: "main...HEAD", rubric: "This is an MCP server; stdout belongs to the transport." })
→ open each finding's path:line; drop false positives; your verdict.

# Same selection, several questions
digest_codebase({ paths: ["src"], root: "<repo>", question: "…", cache: "on" })   # first
digest_codebase({ paths: ["src"], root: "<repo>", question: "…" })                # later ones hit the cache

# Very large selection, or not needed now
digest_codebase({ paths: ["."], root: "<repo>", async: true })   → job id → job_status / job_result
# Above the interactive limit: batch: true (Vertex batch, minutes to hours, batch pricing)

# A recording / a long PDF (Claude cannot hear or watch; the server can)
digest({ file_paths: ["./meeting.wav"], focus: "decisions and owners" })
digest({ file_paths: ["./spec.pdf", "./notes.pdf"], question: "…" })

# Cloud Run errors → digest → Claude infers the fix (read-only by default)
/antigravity:cloud-run-debug --service api --region asia-northeast1 --since 1h

# Grounded research, one call per sub-question; Claude corroborates across domains
search_web({ query: "Vertex AI context caching storage price per token-hour", token_budget: 900 })
```

## Background jobs

`async: true` returns at once with a job id; `job_status` (progress, or the list for
this directory), `job_result` (the same text a synchronous call would have returned,
after the same guards), `job_cancel`. In-process jobs live as long as the server (the
session); Vertex **batch** jobs live in Vertex and survive a restart. Automatic: a
selection above ~300k tokens becomes a job; above the interactive limit (2M) it becomes
a batch job when the driver supports it. Registry: `~/.antigravity-jobs/<id>/`.

## Deep-research recipe (multi-source)

`search_web` is the grounded worker (Google Search grounding on Vertex AI; vertex driver
only): one call per sub-question returns 5–8 dated, URL-cited findings, the sources it
actually used, and a "Not covered:" line. Claude runs the method: plan 3–6 sub-questions
→ one `search_web` each → for every load-bearing claim ask for the exact supporting
sentence (`question: "Quote the sentence(s) supporting: …; otherwise NOT SUPPORTED"`) →
corroborate across ≥2 independent domains → synthesise from verified findings only,
marking the rest "unverified". Grounded citations can be coarse or beside the point;
never ship them unchecked. Use `digest_codebase` / `delegate_task` for the parts that
are *code* reading.

## Prerequisites & limits

- **Node.js 20+** on PATH (the server ships inside the plugin; nothing to install).
- **Credentials:** Application Default Credentials for a Google Cloud project with Vertex
  AI (`gcloud auth application-default login`), or the organisation's gateway credential
  when the server is configured for a gateway. `/antigravity:setup` reports which.
- **Configuration** lives with the server, not in plugin options: `~/.gemini-mcp/config.json`
  for self-serve, `managed-mcp.json` for managed installs (driver, gateway, aliases,
  allowed hosts, allowed roots). See the server's README for every key.
- **Text and images/PDF/audio/video only.** Source is read as text; binaries and media in
  a code selection are skipped and listed under `stats.skipped` (use `digest` for media).
- **Selections are bounded:** 400 files, 512 KB per file, ~2M tokens interactive (batch
  above). Narrow `paths` or add `exclude` rather than raising limits.
- **What moved from 0.x:** the Antigravity CLI transport, its permission grants, write/scaffold
  delegation, internal fan-out, `agy-trace`, `agy-media` (now `digest`), the agy web search
  (now `search_web`) — see `docs/MIGRATION-1.0.md`.
