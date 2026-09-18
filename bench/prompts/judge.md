You are reviewing ONE candidate implementation of a change in a Go repository. Score it in isolation on an absolute 1–5 scale per axis (1 poor, 3 acceptable, 5 excellent). You will not see other candidates and must not guess who or what produced this code. Judge the code, not any test result. An empty or irrelevant diff scores 1 on every axis.

## Requirement given to the implementer
{{prompt}}

## Repository context at the base commit (excerpts)
{{context_pack}}

## Candidate diff (test files are fixed and identical for every candidate; they are not shown)
{{diff}}

## Axes
consistency — matches this codebase's conventions (naming, error handling, package layout, idioms)
edge_cases — handles the boundary and error inputs the requirement implies
scope — does exactly what was asked: no unrelated changes, dead code or gratuitous refactors
readability — clear structure and names; comments only where non-obvious
robustness — failure handling, no panics on bad input, resource and concurrency hygiene where relevant
maintainability — easy to extend; no hidden coupling or duplication

Respond with ONLY this JSON object and nothing else — no prose before or after, no code fence:
{"scores":{"consistency":n,"edge_cases":n,"scope":n,"readability":n,"robustness":n,"maintainability":n},
 "rationale":{"consistency":"one line","edge_cases":"one line","scope":"one line","readability":"one line","robustness":"one line","maintainability":"one line"},
 "flags":[]}
Allowed flags: "unrelated_changes", "incomplete", "suspicious_test_workaround", "generated_code_smell", "empty_diff".
