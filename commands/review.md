---
description: Independent second review of a change by a different model (review_diff), then reconcile as the final judge.
argument-hint: "[--adversarial] [git range, e.g. main...HEAD] [paths...]"
---

Have the `delegation` server's `review_diff` tool read the change with a **different
model family** and report findings anchored to `path:line`; then reconcile the findings
yourself. You are the final judge.

Scope/flags: $ARGUMENTS

Do this:
1. **Choose the scope.** Default: the working tree against `HEAD`. Otherwise pass the git
   `range` (e.g. `HEAD~1`, `main...HEAD`) and optional `paths`. The server runs `git diff`
   itself in `root`; the diff never enters this conversation.
2. **Call** `review_diff({ root, range?, paths?, adversarial?, rubric? })`. If
   `--adversarial` is set, pass `adversarial: true` so it challenges the design decisions
   and trade-offs, not just line bugs. Put the intent of the change, or the team's
   checklist, in `rubric` — a reviewer who knows what the change is for finds more.
3. **Reconcile.** For each finding, open the referenced line and corroborate it against
   the actual code. Drop false positives; keep what is real. Agreement across two model
   families is a stronger signal; disagreement is a prompt to look closer. Note
   `stats.refs_valid_ratio`: findings that do not point at a line shown in the diff are
   suspect by construction.
4. **Report** the reconciled findings, most severe first, and your verdict.
