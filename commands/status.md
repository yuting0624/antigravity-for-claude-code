---
description: List background delegation jobs for this repository, or show one job's status.
argument-hint: "[job-id]"
---

Show background delegation jobs.

- If a job id (or prefix) is given in `$ARGUMENTS`, call `job_status({ job_id: "$ARGUMENTS" })`.
- Otherwise call `job_status({})` to list jobs started for the current directory
  (`all: true` lists every directory).

Report each job's id, tool, state (queued / running / batch_running / done / failed /
cancelled) and task. For finished jobs, remind the user they can fetch the result with
`/antigravity:result <id>`. Batch jobs run on Vertex and may take minutes to hours.
