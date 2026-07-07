---
description: Get an adversarial review challenging your design decisions, security, and edge cases from Antigravity.
argument-hint: "[scope: paths or git range]"
---

Get an independent, adversarial cross-model review of your design decisions, potential security vulnerabilities,
and edge cases from Antigravity (Gemini Pro), then reconcile the findings.

Scope/flags: $ARGUMENTS

Do this:
1. Capture the diff: `git diff` (or the range/paths in the scope above; default to uncommitted + last commit if unspecified).
2. Delegate to agy (pro tier) and pipe the diff on stdin, instructing it to skeptically audit design decisions, potential security gaps, and edge cases:
   `git diff | agy-delegate --tier pro - "Perform an adversarial review of these changes. Skeptically challenge all design decisions, tradeoffs, potential security vulnerabilities, performance bottlenecks, and unhandled edge cases. List each critical finding as 'file:line — issue'."`
3. Reconcile: evaluate each finding. Drop false positives; keep what's real.
4. Report the reconciled design challenges and your verdict.
