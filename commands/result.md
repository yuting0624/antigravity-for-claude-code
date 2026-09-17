---
description: Fetch the result of a finished background delegation job, then verify it.
argument-hint: "<job-id>"
---

Fetch and act on a background job's result.

Call `job_result({ job_id: "$ARGUMENTS" })`.

- If it reports that the job is still running, tell the user the state and stop.
- If finished: the text is the same digest a synchronous call would have returned. Treat
  it under the `antigravity` skill's **Verification gates** — do NOT trust it blindly.
  Open the `file:line` references behind anything you will act on, run or grep to confirm
  load-bearing claims, and report your verification.
- If failed: relay the message and the `error:` envelope; `retry: true` means the same
  call can simply be repeated later.
