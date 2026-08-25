---
description: Get an independent cross-model review of the current diff from an executor (local model for privacy, or Gemini), then reconcile as the final judge.
argument-hint: "[--adversarial] [--backend local|agy] [scope: paths or git range]"
---

Use an executor as an **independent, different-model reviewer** of the current changes,
then reconcile the findings yourself (you are the final judge).

Scope/flags: $ARGUMENTS

Do this:
1. Capture the diff: `git diff` (or the range/paths in the scope above; default to
   uncommitted + last commit if unspecified).
2. Pick the reviewer backend (default: **local** — the diff stays on your machine; use
   `--backend agy` for a Gemini cross-check or when no local server is running).
3. Delegate the review — pipe the diff in on stdin:
   - local (private): `git diff | bash <pkg>/scripts/local-delegate.sh --tier think -`
   - agy (Gemini): `git diff | bash <pkg>/scripts/agy-delegate.sh --backend agy --tier pro -`
   where `<pkg>` is two levels above the `antigravity-glm` skill directory. (The
   registered `delegate` tool cannot receive piped stdin — use bash for reviews.)
4. Instruct the reviewer to find correctness/security/performance bugs, be skeptical,
   and list each as `file:line — issue`. With `--adversarial`, also have it challenge
   design decisions and tradeoffs, not just line bugs.
5. **Reconcile**: for each finding, corroborate it against the actual code. Drop false
   positives; keep what's real. Agreement across model families is a stronger signal;
   disagreement is a prompt to look closer. (A local model's review is weaker on
   average — treat its findings as leads, not verdicts.)
6. Report the reconciled findings (most severe first) and your verdict.
