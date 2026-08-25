---
description: Delegate a well-scoped subtask to an executor (agy/Gemini or the local model server) under cost discipline, then verify.
argument-hint: "[--backend agy|local] [--tier flash|pro|fast|think] <task>"
---

Delegate the following task using the plugin's delegation discipline (see the
`antigravity-glm` skill for the full policy).

Task: $ARGUMENTS

Do this:
1. **Pick the executor backend** (default auto = agy if installed, else local):
   - **agy (Gemini)** for agentic repo work — it reads/writes files (`dir` = repo root,
     so it loads AGENTS.md + real code; don't paste files into context), runs terminal,
     web / Vertex AI Search. **If the task WRITES files or uses tools** it needs a grant:
     the narrower one is a `write_file(<real-dir>)` entry under `permissions.allow` in
     `~/.gemini/antigravity-cli/settings.json`; otherwise **`--yolo`** (approves ALL tools —
     what web search / terminal need). Run write tasks on a dedicated branch and verify
     with `git status`. Wrapper exit `15` = permission denied — soft deny on agy 1.1.3 and hard error on 1.1.13 alike,
     same fix for both. `--sandbox` is not containment.
   - **local (Ollama/LM Studio/vLLM)** for private generation — tests, scaffolds as text,
     summaries, reviews of pasted diffs. NO file access (put content in the prompt or pipe
     via stdin when using the CLI); writes land via `out` (the wrapper writes, nothing
     executes). `--yolo`/`--dir` have no effect there.
2. Pick a tier: agy `flash` (default) / `pro` (hard reasoning); local `fast` / `think`.
3. Call the **`delegate` tool** with the matching options (`prompt`, `backend`, `tier`,
   `dir`, `yolo`, `digest`, `out`, `web`, `timeout`) — or run the wrapper from bash:
   `<pkg>/scripts/agy-delegate.sh --backend <b> --tier <t> [--digest] "<task>"` (path =
   two levels above the `antigravity-glm` skill dir). Run **synchronously**: wait for the
   result before continuing (in print mode there is no later turn). Long interactive task?
   Use the **`job` tool** (action=start) instead, then check with `/agy-status`.
4. Ingest only the **result/digest** — do NOT re-read files an executor already handled.
   If stderr warns "looks like a raw dump", do NOT ingest raw output — re-run with digest/out.
5. **Verify**: actually run/check the output; never trust a self-reported "done".
   Report what you delegated and how you verified it.

Remember the break-even: only delegate if the offloaded volume clearly exceeds the
spec + round-trip + verification overhead. Tiny tasks are cheaper to just do yourself.
(The local backend's marginal token cost is ~0 — there the tradeoff is quality/wait, and
privacy is often worth it regardless.)
