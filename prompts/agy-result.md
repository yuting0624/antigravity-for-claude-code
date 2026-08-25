---
description: Fetch the output of a finished background delegation job, then verify it.
argument-hint: "<job-id>"
---

Fetch and act on a background job's result.

Use the **`job` tool** with action=result and id=$ARGUMENTS.

- If it reports "still running", tell the user and stop.
- If finished: treat the output as a delegated result under the `antigravity-glm` skill's
  **Verification gates** — do NOT trust it blindly. Verify (run/inspect) before using,
  ingest only the digest into your context, and report your verification. (Jobs may run
  on either executor — agy or local; the exit-code labels cover both.)
