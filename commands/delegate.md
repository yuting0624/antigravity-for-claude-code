---
description: Delegate a well-scoped subtask to Antigravity (agy/Gemini) under cost discipline, then verify.
argument-hint: "[--tier flash|pro] <task>"
---

Delegate the following task to Antigravity (`agy` / Gemini) via the plugin wrapper,
following the `antigravity` skill's **Cost discipline** and **Verification gates**.

Task: $ARGUMENTS

Do this:
1. Pick a tier (`flash` default; `pro` for hard reasoning). If the task needs the repo,
   add `--dir <repo-root>` so agy reads the real files (don't paste them into context).
   **If the task WRITES files**, grant write permission — without it, headless agy
   describes the edits or writes them to its **own scratch dir**, NOT your workspace,
   while still reporting success (issue #10):
   - Pure file writes (implement / scaffold / test-gen / migrate / fix): **`--mode
     accept-edits`** (agy ≥ 1.1.0) — auto-applies edits *without* granting terminal/tool
     permissions. Prefer this.
   - Task also needs tools (web / Vertex AI Search / terminal): **`--yolo`**. Claude Code
     may prompt for or block `--dangerously-skip-permissions` — approve it when asked, or
     pre-allow it; non-interactive (`claude -p`) without that permission can't use tools via agy.
   - Either way: run write tasks on a dedicated branch (+ `--sandbox`), and **verify files
     actually changed in the workspace** (`git status`).
2. Run **synchronously** (you may be headless — do not background-and-wait):
   `agy-delegate --tier <tier> [--dir .] [--mode accept-edits | --yolo] [--digest] "<task>"`
   For read/analysis tasks, add `--digest` — it appends a digest-only output contract so
   agy returns compact bullets instead of raw content.
3. Ingest only the **result/digest** — do NOT re-read the files agy already handled
   (keeps your context lean; that's where the cost savings come from). If the wrapper
   prints a *"looks like a raw dump"* note on stderr, do NOT ingest the raw output —
   re-run with `--digest` or ask agy to summarize it first.
4. **Verify**: actually run/check the output; never trust a self-reported "done".
   Report what you delegated and how you verified it.

Remember the break-even: only delegate if the offloaded volume clearly exceeds the
spec + round-trip + verification overhead. Tiny tasks are cheaper to just do yourself.

**Long task, interactive session?** A sync delegation can also hit Claude Code's ~2-min
Bash-tool limit — start it in the background and keep working (this also keeps the prompt
cache warm and frees you to do other turns):
`ID=$(agy-job start --tier pro --dir . "<task>")`
then check `/antigravity:status` and collect with `/antigravity:result <id>`.
(Don't do this when YOU are headless `claude -p` — one-shot, no later turn to collect;
delegate synchronously there.)
