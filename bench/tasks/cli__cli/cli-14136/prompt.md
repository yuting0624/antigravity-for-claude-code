## Context
`gh issue develop` creates or lists development branches linked to an issue; with
`--checkout` it checks the linked branch out in the caller's current working copy,
which interrupts whatever branch is already checked out there. `gh pr checkout`
already has worktree-related helpers in its shared package that this feature can build
on.

## Requirement
- Add `--worktree <path>` to `gh issue develop`. Combined with `--checkout`, the linked
  branch is created as usual but checked out in a new Git worktree at that path; the
  original working copy stays on its current branch.
- If the linked branch does not exist locally, create it in the new worktree as a
  tracking branch from the matching remote branch; if it already exists locally, add a
  worktree for it and attempt the same fast-forward-only pull the existing checkout flow
  performs, scoped to the new worktree.
- The remote is still chosen from the linked branch's repository, so `--branch-repo`
  keeps working when issue and development branch live in different repositories.
- Relative paths are normalised to absolute paths; a path containing spaces is passed
  to Git as a single argument.
- Validation: `--worktree` requires `--checkout`, rejects an explicitly blank path, and
  is mutually exclusive with `--list`. Without `--worktree`, behaviour is unchanged.
- Expose the two Git operations through a reusable helper on the git client
  (`git worktree add -- <path> <existing-branch>` and
  `git worktree add --track -b <new-branch> -- <path> <remote>/<new-branch>`), and
  resolve and validate the worktree target through the shared pull-request checkout
  package so both commands share the path rules.
- Help text and the command's flag docs describe the new flag and its constraints.

## Constraints
- Go; no new module dependencies; follow the conventions of the surrounding command
  packages and their table-driven tests; keep existing exported behaviour intact.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
These test files were added or updated in this checkout and currently fail; make them
pass without modifying them and keep `go test ./...` green (the `acceptance/` package is
not part of the suite here): `pkg/cmd/issue/develop/develop_test.go`,
`pkg/cmd/pr/checkout/checkout_test.go`, `pkg/cmd/pr/shared/worktree_test.go`.
Two acceptance scenarios were also added, `acceptance/testdata/issue/issue-develop-worktree.txtar`
and `acceptance/testdata/issue/issue-develop-worktree-cross-repo.txtar`; they need a live
GitHub and are not run here.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
