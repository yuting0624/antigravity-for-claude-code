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
   **If the task WRITES files or uses tools** (web / Vertex AI Search / terminal), it needs
   a grant. For a plain file write the narrower one is a `write_file(<dir>)` entry under
   `permissions.allow` in `~/.gemini/antigravity-cli/settings.json` (recursive beneath
   `<dir>`, no flag needed — substitute a real path for `<dir>`; if a rule is already
   there and the write is still denied, `agy-doctor` checks whether agy can parse it). Otherwise pass **`--yolo`**, which auto-approves all tools and
   is what web / Vertex AI Search / terminal need. Without a grant,
   headless agy leaves your workspace untouched, and only the newest versions admit it (it
   describes / scratch-diverts / soft-denies / fails outright depending on version; issue #10). `--mode
   accept-edits` is not a grant either: measured on agy 1.1.13, where the flag is applied
   at all, the write is denied exactly like one without it. Run
   write tasks on a dedicated branch (+ `--sandbox`), and
   **verify files actually changed** with `git status`. Claude Code may prompt for or block
   `--dangerously-skip-permissions` — approve it or pre-allow it; non-interactive
   (`claude -p`) without that permission can't write/use-tools via agy. (If the wrapper
   returns exit `15`, that's exactly this: agy denied the write. Both shapes land here —
   the soft deny on agy 1.1.3 and the hard error on 1.1.13 — and both take the same
   fix: a `permissions.allow` rule covering the target, or `--yolo`.)
2. Run **synchronously** (you may be headless — do not background-and-wait):
   `agy-delegate --tier <tier> [--dir .] [--yolo] [--digest] "<task>"`
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
