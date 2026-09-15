# Task prompt template (20–30 lines; requirements only)

Writing rules, enforced by `bench.py lint-prompt`:
- No function, type, field, method or flag identifier that the author's patch introduces,
  unless it already appears in the hidden test files (those are unavoidable and allowed).
- No non-test file paths from the author's patch; no PR title, number, author or date.
- No hints about approach or structure; describe observable behaviour.
- Name where the given test files are and that they must pass unmodified.

---
## Context
<2–4 lines: what the tool does, which area of behaviour this touches, no paths>

## Requirement
<10–18 bullet lines of observable behaviour: inputs, outputs, errors, edge cases the tests exercise>

## Constraints
- Go; no new module dependencies; keep existing behaviour and follow the codebase's conventions.
- `gofmt`-clean; `go vet ./...` clean.

## Tests
The test files at <paths> were added to this checkout and currently fail. Make them pass
without modifying them. `go test ./...` must stay green.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches or tags.
