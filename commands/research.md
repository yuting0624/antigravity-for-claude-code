---
description: Claude-orchestrated deep research — the delegation server's `search_web` (Google Search grounding on Vertex AI) does the grounded legwork; Claude plans, verifies the citations across independent sources, and synthesizes.
argument-hint: "<what to research>"
---

Run a multi-source research pass on the topic below, following the `antigravity`
skill's **Deep-research recipe** and **Verification gates**. `search_web` is the cheap,
grounded worker: it returns dated, URL-cited findings and the sources it actually used,
while the pages stay on the cheap side. **You (Claude) own the plan, the verification,
and the synthesis.** Grounded citations can still be coarse or beside the point, so never
ship them unchecked.

Topic: $ARGUMENTS

If the topic is empty, ask the user what to research (AskUserQuestion) before starting.

Do this:
1. **Plan.** Break the topic into 3–6 sub-questions and list the load-bearing claims that
   must be verified. You own scope and final synthesis.
2. **Fan-out fetch.** One `search_web({ query: <sub-question> })` per sub-question. Keep
   the bullet findings and the source list; do not ask for whole pages.
3. **Deepen on each load-bearing claim.** `search_web({ query: <source or topic>,
   question: "Quote the exact sentence(s) supporting: '<claim>'. If nothing supports it,
   say NOT SUPPORTED." })`, or open the URL yourself with WebFetch when a quote is needed
   verbatim.
4. **Adversarially verify.** Corroborate each key claim across ≥2 independent domains;
   treat any single, vague or domain-only citation as unverified; sanity-check dates;
   watch for general knowledge posing as a sourced fact ("Not covered:" lines are honest
   signals — use them).
5. **Synthesize.** Write a cited report from verified findings only; mark anything
   uncorroborated as "unverified".

Keep your own context lean — ingest the findings, not the pages. Each `search_web` call
is one grounded pass; re-dispatch follow-up calls to close gaps rather than expecting it
to iterate. If the research needs the *code* read, use `digest_codebase` /
`delegate_task` for that part. `search_web` needs the vertex driver (Vertex AI mode);
behind a compatibility-mode gateway, run the searches with your own tools.
