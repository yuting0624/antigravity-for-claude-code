---
description: List background Antigravity (agy) delegation jobs for this repo, or show one job's status.
argument-hint: "[job-id]"
---

Show background delegation jobs (either executor).

Use the **`job` tool**:
- A job id in `$ARGUMENTS` → action=status with that id.
- Otherwise → action=list (lists jobs started from this directory).

Report each job's id, state (running / done / failed), and task. For finished jobs,
remind the user they can fetch output with `/agy-result <id>`.
