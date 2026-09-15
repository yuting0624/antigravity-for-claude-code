## Context
Zoekt is a code search engine; its `gitindex` package indexes Git repositories into
shard files under an index directory, and the repository already ships several
`cmd/zoekt-*` commands built on it. There is no command for keeping a *local* index in
sync with the repositories under a few directories on the same machine.

## Requirement
- Add a self-contained command `zoekt-local-sync`. Given one or more root directories,
  it discovers the Git repositories beneath them (a root that is itself a repository
  counts), derives each repository's name from its path relative to the root, and
  refuses to continue when two repositories would get the same name.
- The default action is a preview: it reports which repositories would be indexed and
  which existing indexed repositories would be pruned because they are outside the
  selected roots, and changes nothing. `-f` applies the plan: index the discovered
  repositories with the existing git indexer and remove shards of repositories that are
  no longer under any root. A dry run must never write or delete.
- Subcommands: `list` prints the repositories currently in the index; `remove` previews,
  or with `-f` applies, removal of the named repositories. Running without a root prints
  usage and fails.
- The usual indexing options (index directory, branch, submodules, and so on) are
  accepted, and `-h` for the command and for each subcommand names that subcommand and
  the default option values.
- Indexing a repository must preserve the repository name chosen by discovery in the
  shard metadata, so `list` and pruning agree with discovery; the change to the shared
  git indexer needed for that must keep every existing caller's behaviour.
- Concurrent runs against the same index directory are guarded by a lock so two syncs
  cannot interleave writes.

## Constraints
- Go; no new module dependencies; follow the structure of the sibling `cmd/zoekt-*`
  programs and the conventions of the `gitindex` package; a `git` binary is available.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
These test files were added or updated in this checkout and currently fail; make them
pass without modifying them and keep `go test ./...` green:
`cmd/zoekt-local-sync/discover_test.go`, `cmd/zoekt-local-sync/index_test.go`,
`cmd/zoekt-local-sync/main_test.go`, `gitindex/index_test.go`.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
