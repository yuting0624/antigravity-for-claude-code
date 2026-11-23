---
description: Delegate a well-scoped subtask to Antigravity (agy/Gemini) under cost discipline, then verify.
argument-hint: "[--tier flash|flash-lo|pro] [--effort low|medium|high|xhigh] <task>"
---

Delegate the following task to Antigravity (`agy` / Gemini) via the plugin wrapper,
following the `antigravity` skill's **Cost discipline** and **Verification gates**.

Task: $ARGUMENTS

Do this:
1. Pick a tier (`flash` default = Gemini 4 Hydrogen High; `flash-lo` = Gemini 4 Hydrogen Low; `pro` = Gemini 4 Neon High, plus aliases `neon`/`carbon`/`argon`/`flash-38`; auto-falls-back on plans without Neon/Carbon/Hydrogen). If the task needs the repo,
   add `--dir <repo-root>` (or `--dir .` inside the `antigravity-delegate` subagent, whose gate confines `-d`/`--dir`/`--add-dir` to `cwd`) so agy reads the real files (don't paste them into context).
   - **Read/analysis tasks**: pass `--read-only` (and `--allow-url` if reading web URLs) so `agy 1.5.7+` default `Auto` mode cannot edit files or run shell commands.
   - **Workspace file-edit tasks** (no terminal needed): on `agy 1.5.7+`, `--mode accept-edits` auto-approves `write_file` inside `--dir` / `--add-dir` while denying every shell command (`run_command`) — so prompts using `--mode accept-edits` without `--yolo` must instruct `agy` to *edit files only and not run shell or test commands* (or use a `write_file(<dir>)` entry in `permissions.allow` in `~/.gemini/antigravity-cli/settings.json`).
   - **Full agentic tasks** (running tests/shell commands, Vertex AI Search): pass **`--yolo`**, which auto-approves all tools unless blocked by enterprise admin policy. Run
   write tasks on a dedicated branch — `--sandbox` is not containment, it was measured
   doing nothing under `--yolo` — and
   **verify files actually changed** with `git status`. Claude Code may prompt for or block
   `--dangerously-skip-permissions` — approve it or pre-allow it; non-interactive
   (`claude -p`) without that permission can't run `--yolo` via agy. (If the wrapper
   returns exit `15`, agy denied a tool interaction — covering both the soft deny back since
   agy 1.1.20 and 1.1.13's hard error — and names the refused tool from `denied_actions` or stderr; exit `16` `CLI_FLAG_ERROR` means `agy` rejected a CLI flag or option value.)
2. Run **synchronously** (you may be headless — do not background-and-wait):
   `agy-delegate --tier <tier> [--read-only | --mode accept-edits | --yolo] [--dir .] [--digest] "<task>"`
   For read/analysis tasks, add `--digest` — it appends a digest-only output contract so
   agy returns compact bullets instead of raw content.
3. Ingest only the **result/digest** — do NOT re-read the files agy already handled
   (keeps your context lean; that's where the cost savings come from). If the wrapper
   prints a *"looks like a raw dump"* note on stderr, do NOT ingest the raw output —
   re-run with `--digest` or ask agy to summarize it first.
4. **Verify**: actually run/check the output; never trust a self-reported "done".
   On any write delegation — including empty output (exit `3`), timeout (exit `12`), tool denial, or a summary from the `antigravity-delegate` subagent (which cannot run `git`) — always run `git status` and `git diff` yourself before concluding nothing changed. Report what you delegated and how you verified it.

Remember the break-even: only delegate if the offloaded volume clearly exceeds the
spec + round-trip + verification overhead. Tiny tasks are cheaper to just do yourself.

**Long task, interactive session?** A sync delegation can hit Claude Code's ~2-min default / 10-min max
Bash-tool limit (notably write runs now default `--print-timeout` to `25m`) — start long interactive writes in the background via `agy-job start` (or raise Bash's `timeout` up to `600000` ms) and keep working (this also keeps the prompt
cache warm and frees you to do other turns):
`ID=$(agy-job start --tier pro --dir . "<task>")`
then check `/antigravity:status` and collect with `/antigravity:result <id>`.
(Don't do this when YOU are headless `claude -p` — one-shot, no later turn to collect;
delegate synchronously there.)
