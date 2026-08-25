---
description: Claude-orchestrated deep research — Antigravity (agy/Gemini) does the grounded web legwork; Claude plans, verifies the citations, and synthesizes.
argument-hint: "<what to research>"
---

Run a multi-source research pass on the topic below, following the `antigravity`
skill's **Deep-research recipe** and **Verification gates**. Antigravity (`agy` / Gemini)
is the cheap, grounded search worker; **you (Claude) own the plan, the verification, and
the synthesis**. agy's print-mode citations are coarse (often domain-level) and it can
present parametric "knowledge" as a sourced fact — so never ship its citations unchecked.

Topic: $ARGUMENTS

If the topic is empty, ask the user what to research (AskUserQuestion) before starting.

Do this:
1. **Plan (you).** Break the topic into 3–6 sub-questions and list the load-bearing claims that must be verified. You own scope and final synthesis.
2. **Fan-out fetch (agy, cheap, one call per sub-question).** Web search needs `--yolo` in headless mode; force compact output so bulky pages stay on Gemini's side, not yours:
   `agy-delegate --tier flash --yolo "Web-search <sub-question>. Return 5–8 bullet findings, each with the exact source URL and publication date. Output ONLY findings + URLs + dates."`
3. **Deepen on each load-bearing claim (agy).** Name the URL and have agy quote the supporting sentence(s), turning domain-level citations into verifiable quotes:
   `agy-delegate --tier pro --yolo "Open <URL> and quote the exact sentence(s) supporting: '<claim>'. If the page does not support it, reply NOT SUPPORTED."`
4. **Adversarially verify (you).** Corroborate each key claim across ≥2 independent domains; treat any single / vague / domain-only citation as unverified; sanity-check dates; watch for Gemini parametric knowledge posing as a sourced fact.
5. **Synthesize (you).** Write a cited report from verified findings only; explicitly mark anything uncorroborated as "unverified".

Keep your own context lean — ingest agy's bullet digests, not the raw pages (that's where the cost savings come from). `--print` does one agentic pass per call, so re-dispatch follow-up agy calls to close gaps rather than expecting it to auto-iterate. In an interactive session a long fetch can be backgrounded with `agy-job`; when **you** are headless (`claude -p`), delegate synchronously.
