---
description: Diagnose a failing Cloud Run service — Antigravity (agy/Gemini) digests the error logs cheaply, Claude infers the root cause and proposes a fix. Read-only by default; --apply writes the fix to a branch.
argument-hint: "[--service <name>] [--region <r>] [--since 1h] [--limit 200] [--apply]"
---

Diagnose a broken Cloud Run service. This is a **Conductor / Executor** split: **you (Claude)
conduct** — confirm scope, reason about the root cause, and propose the fix — while the cheap,
high-volume work (pulling and clustering potentially hundreds of error log lines) is **offloaded
to agy (Gemini)** so your context stays lean. You ingest only agy's digest, never the raw logs.

Flags: $ARGUMENTS

Defaults: `--since 1h`, `--limit 200`, **read-only** (diagnosis only). `--apply` is the only
thing that writes anything, and only ever onto a branch for human review. For a chatty service,
narrowing `--since` tightens the digest (and cost) further.

Do this:

1. **Resolve scope.** Parse the flags above.
   - `--service` is required. If it's missing, ask the user which Cloud Run service to diagnose
     (AskUserQuestion) — there is no "default service".
   - `--region` is optional; if omitted, logs across all regions are queried. If the user's
     `gcloud config` has a default region you can offer it.
   - Never ask for or handle credentials/tokens — the engine uses the existing `gcloud` ADC.

2. **Fetch + digest (delegate to agy — one batch, not parallel).** Run the plugin's read-only
   engine, which pulls `severity>=ERROR` logs via `gcloud logging read` and hands them to agy for
   a structured digest (error clusters / representative stack traces / time distribution / likely
   root-cause candidates):
   `cloud-debug --service <name> [--region <r>] [--since <dur>] [--limit <n>]`
   - **Ingest only the digest** it prints — do **not** re-fetch or paste the raw logs into your
     context (that lean handoff is where the cost saving comes from).
   - If it exits **3** (permission denied), relay the `roles/logging.viewer` guidance it printed
     and stop — the user must grant access first. Exit **4** means `gcloud` isn't installed.
   - If it reports no matching logs, widen `--since` / lower severity, or re-confirm the
     service/region with the user.

3. **Diagnose (you).** From the digest, infer the most likely root cause (e.g. a missing env var,
   an unhandled exception, bad config, a dependency timeout). State the reasoning and the evidence
   (which cluster / trace supports it). Then propose a **concrete fix** — the exact code, config,
   or environment change — and how to verify it.

4. **Apply only if `--apply` was passed.** Default is diagnosis-only; do **not** modify anything
   without `--apply`.
   - Work on a **dedicated branch** (create/switch to one; never the user's working branch).
   - Apply the proposed fix, then **show the diff** and stop. Do **not** deploy and do **not**
     merge — a human reviews and merges.
   - Confirm before any destructive or hard-to-reverse step.

Keep it tight: the demo is Claude conducting the diagnosis while a cheaper model does the log
grunt-work. Report what you delegated, the root cause you landed on, and the fix (plus the diff
if `--apply`).
