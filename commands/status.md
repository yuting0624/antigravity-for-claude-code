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

If a `--tier pro` job was retried with a fallback model, its stderr carries
`agy-delegate: pro fell back to …` — visible through `/antigravity:result <id>` (which prints
the job's stderr after a `----- stderr -----` marker), not in the status listing. An unremapped
`pro` can do that up to twice, only on agy's "model not recognized" error and never after a
timeout; each rejected start took 5–37 s on agy 1.4.2, so the fallback explains a job that is
a minute late, not one that is still `running` past its timeout. `AGY_USAGE.model` in the same
stderr names the model that actually ran.
