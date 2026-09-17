---
description: Cancel a running background delegation job.
argument-hint: "<job-id>"
---

Call `job_cancel({ job_id: "$ARGUMENTS" })`.

Confirm to the user whether it was cancelled or had already finished. A batch job is
cancelled on Vertex as well, and its staged input is removed.
