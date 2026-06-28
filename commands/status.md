---
description: List background Antigravity (agy) delegation jobs for this repo, or show one job's status.
argument-hint: "[job-id]"
---

Show background agy delegation jobs.

- If a job id is given in `$ARGUMENTS`, run:
  `agy-job status $ARGUMENTS`
- Otherwise list jobs started from this directory:
  `agy-job list`

Report each job's id, state (running / done / failed), and task. For finished jobs,
remind the user they can fetch output with `/antigravity:result <id>`.
