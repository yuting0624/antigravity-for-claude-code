---
description: Claude-orchestrated deep research — Antigravity (agy/Gemini) does the grounded web legwork; Claude plans, verifies the citations, and synthesizes.
argument-hint: "[--tier flash|flash-lo|pro] [--timeout 15m] <what to research>"
---

Run a multi-source research pass on the topic below, following the `antigravity`
skill's **Deep-research recipe** and **Verification gates**. Antigravity (`agy` / Gemini)
is the fast, grounded search worker (`flash` = Gemini 4 Hydrogen High, ~2.5x faster on
multi-query research loops; auto-falls-back to 3.8 Flash High on plans without Hydrogen);
**you (Claude) own the plan, the verification, and the synthesis**. agy's print-mode
citations are coarse (often domain-level) and it can present parametric "knowledge" as a
sourced fact — so never ship its citations unchecked.

Input: $ARGUMENTS

Parse optional `--tier <flash|flash-lo|pro>` (default `flash` for step 2 fan-out search; if passed, use it for step 2, while keeping `pro` for step 3 quote verification unless `--tier` was explicitly set to override all calls) and `--timeout <dur>` (default `15m` for step 2 fan-out search — multi-query web search + URL reads routinely take 3–5 min per call and hit `agy-delegate`'s 5m default, #115; default `10m` for step 3 single-URL verification). If the remaining topic is empty, ask the user what to research (AskUserQuestion) before starting.

Do this:
1. **Plan (you).** Break the topic into 3–6 sub-questions and list the load-bearing claims that must be verified. You own scope and final synthesis.
2. **Fan-out fetch (agy, one call per sub-question).** On `agy >= 1.4.10`, pass `--read-only --allow-url` (sets `toolPermission: "request-review"`, `permissions.allow: ["read_url(*)"]`, and `permissions.ask: ["write_file(*)", "command(*)"]`, permitting web search and URL reads while keeping file writes and shell commands blocked across both consumer and Gemini Enterprise accounts; on older `agy < 1.4.10` where `--settings` is unavailable, fall back to `--yolo` if URL reads hit exit `15` — covering both the soft deny from 1.1.20+ and 1.1.13's hard error, with `denied_actions` naming `read_url`):
   `agy-delegate --read-only --allow-url --tier <search-tier> --timeout <timeout> "Web-search <sub-question>. Return 5–8 bullet findings, each with the exact source URL and publication date. Output ONLY findings + URLs + dates."`
   If a call exits `12` (`TIMEOUT`), `agy-delegate` prints whatever partial findings agy already gathered to stdout — salvage usable URLs from that partial output, then narrow the sub-question or resume with `--continue --timeout <longer>`.
3. **Deepen on each load-bearing claim (agy).** Name the URL and have agy quote the supporting sentence(s), turning domain-level citations into verifiable quotes:
   `agy-delegate --read-only --allow-url --tier pro --timeout <quote-timeout> "Open <URL> and quote the exact sentence(s) supporting: '<claim>'. If the page does not support it, reply NOT SUPPORTED."`
4. **Adversarially verify (you).** Corroborate each key claim across ≥2 independent domains; treat any single / vague / domain-only citation as unverified; sanity-check dates; watch for Gemini parametric knowledge posing as a sourced fact.
5. **Synthesize (you).** Write a cited report from verified findings only; explicitly mark anything uncorroborated as "unverified".

Keep your own context lean — ingest agy's bullet digests, not the raw pages (that's where the cost savings come from). `--print` does one agentic pass per call, so re-dispatch follow-up agy calls to close gaps rather than expecting it to auto-iterate. In an interactive session where Claude Code's synchronous Bash tool caps calls at 10m (unless `BASH_MAX_TIMEOUT_MS` is raised), run `15m` fan-out searches via `agy-job start` (or pass `--timeout 9m` synchronously) so the Bash tool does not cut off partial output; when **you** are headless (`claude -p`), delegate synchronously within the Bash tool timeout.
