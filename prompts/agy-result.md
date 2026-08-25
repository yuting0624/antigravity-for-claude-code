---
description: Fetch the output of a finished background Antigravity (agy) job, then verify it.
argument-hint: "<job-id>"
---

Fetch and act on a background agy job's result.

Run: `agy-job result $ARGUMENTS`

- If it reports "still running", tell the user and stop.
- If finished: treat the output as a delegated result under the `antigravity` skill's
  **Verification gates** — do NOT trust it blindly. Verify (run/inspect) before using,
  ingest only the digest into your context, and report your verification.
