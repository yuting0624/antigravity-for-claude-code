---
description: Conductor-orchestrated deep research — executors do the grounded web legwork (agy's Gemini tools, or local --web); the conductor plans, verifies citations, and synthesizes.
argument-hint: "<what to research>"
---

Run a multi-source research pass on the topic below, following the `antigravity-glm`
skill's **Deep-research recipe** and **Verification gates**. The executor is the cheap,
grounded search worker; **you own the plan, the verification, and the synthesis**.
Executor citations are coarse (agy's print mode returns search summaries; local `--web`
returns wrapper-fetched snippets) and either can present parametric "knowledge" as a
sourced fact — so never ship citations unchecked.

Topic: $ARGUMENTS

If the topic is empty, ask the user what to research before starting.

Do this:
1. **Plan (you).** Break the topic into 3–6 sub-questions and list the load-bearing
   claims that must be verified. You own scope and final synthesis.
2. **Fan-out fetch (executors, cheap, one call per sub-question).** Force compact output
   so bulky pages stay on the executor's side, not yours. Use the **`delegate` tool**:
   - agy (native web tools; needs `yolo`): backend=agy, tier=flash, yolo=true,
     prompt=`Web-search <sub-question>. Return 5–8 bullet findings, each with the exact
     source URL and publication date. Output ONLY findings + URLs + dates.`
   - local (wrapper fetches; query goes to DuckDuckGo or your SearXNG — set
     `LOCAL_SEARXNG_URL` to keep even that on your infra): backend=local, tier=fast,
     web=true, prompt=`Search: <sub-question>. Return 5–8 bullet findings, each cited [n]
     with its URL. ONLY findings + citations.`
3. **Deepen on each load-bearing claim.** Name the URL and have the executor quote the
   supporting sentence(s), turning coarse citations into verifiable quotes; if it does
   not support the claim it must reply NOT SUPPORTED. (agy can fetch a URL itself; the
   local backend cannot — paste the page text into the prompt for it.)
4. **Adversarially verify (you).** Corroborate each key claim across ≥2 independent
   domains; treat any single / vague / domain-only citation as unverified; sanity-check
   dates; watch for parametric model knowledge posing as a sourced fact.
5. **Synthesize (you).** Write a cited report from verified findings only; explicitly
   mark anything uncorroborated as "unverified".

Keep your own context lean — ingest bullet digests, not the raw pages. `--print` does one
agentic pass per call, so re-dispatch follow-up calls to close gaps rather than expecting
auto-iteration. In an interactive session a long fetch can be backgrounded with the
**`job` tool**; when you are headless (`pi -p`), delegate synchronously.
