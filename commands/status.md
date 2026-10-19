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

A `--tier pro` job that is still running well past its timeout is not necessarily stuck:
an unremapped `pro` can retry up to twice with a fallback model (see `AGY_SIGNAL` /
`pro fell back to …` in the job's stderr), so allow up to 3 × the timeout before calling it hung.
