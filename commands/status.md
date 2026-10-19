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

If a `--tier pro` job's stderr shows `agy-delegate: pro fell back to …`, the run was retried
with a fallback model (an unremapped `pro` can do that up to twice). The retry fires only on
agy's immediate "model not recognized" error, never after a timeout, so it adds a quick failed
start or two, not extra timeouts — a job that is still `running` past its timeout is not
explained by the fallback. `AGY_USAGE.model` in the stderr names the model that actually ran.
