---
description: List background Antigravity (agy) delegation jobs for this repo, or show one job's status.
argument-hint: "[job-id]"
---

Show background agy delegation jobs.

- If a job id is given in `$ARGUMENTS`, run:
  `agy-job status $ARGUMENTS`
- Otherwise list jobs started from this directory:
  `agy-job list`

Report each job's id, state (running / done / failed / cancelled), and task. For finished jobs,
remind the user they can fetch output with `/antigravity:result <id>`.

If an unremapped tier job (`--tier pro`, `--tier flash`, `--tier flash-lo`) was retried with
or served from a plan-fallback model, its stderr carries `agy-delegate: <tier> fell back to …`
— visible through `/antigravity:result <id>` (which prints the job's stderr after a
`----- stderr -----` marker), not in the status listing. On a cold miss `agy-delegate`
intersects the fallback chain against `agy`'s `Available models:` hint (jumping in one hop)
and caches the working model for 6 hours so subsequent jobs pay zero retry delay, and never
retries after a timeout. `AGY_USAGE.model` in the same stderr names the model that actually ran.
