# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #1105 local: add zoekt-local-sync for maintaining local indexes (merged 2026-07-29T13:59:38Z)

This adds a new self-contained `zoekt-local-sync` command focused on using Zoekt locally. Expected usage is lightweight: preview synchronization with `zoekt-local-sync ~/src`, then apply it with `zoekt-local-sync -f ~/src`. The command also supports `list` for inspecting indexed repositories and `remove` for explicitly previewing or applying repository removal.

The supplied roots intentionally describe the complete desired index, which keeps stale repositories pruned, while preview-by-default makes that reconciliation safe to inspect before applying.

This is the initial shape of the local workflow and is expected to change based on usage and feedback.

## Files (code)

- cmd/zoekt-local-sync/discover.go
- cmd/zoekt-local-sync/index.go
- cmd/zoekt-local-sync/main.go
- gitindex/index.go

## Hidden tests

- cmd/zoekt-local-sync/discover_test.go
- cmd/zoekt-local-sync/index_test.go
- cmd/zoekt-local-sync/main_test.go
- gitindex/index_test.go

## Test functions

- BenchmarkPrepareNormalBuild
- TestCatfileFilterSpec
- TestDirectoryLock
- TestDiscoverRepositories
- TestDiscoverRepositoriesRejectsDuplicateNames
- TestDiscoverRootRepository
- TestHelpIncludesDefaultOptionsAndSubcommands
- TestIndexDeltaBasic
- TestIndexEmptyRepo
- TestIndexGitRepoPreservesRepositoryName
- TestIndexGitRepo_BareRepo_LegacyRepoOpen
- TestIndexGitRepo_CatfileFilterUnsupportedFallsBack
- TestIndexGitRepo_Worktree
- TestIndexNonexistentRepo
- TestIndexTinyRepo
- TestListAndRemove
- TestOpenRepoVariants
- TestSetTemplates
- TestSetTemplates_Worktree
- TestSetTemplates_e2e
- TestSyncDefaultsToPreview
- TestSyncDryRunAndForcePrune
- TestSyncHelpUsesSyncCommandName
- TestSyncIndexesWithRootRelativeName
- TestSyncPrunesRepositoriesOutsideSelectedRoots
- TestSyncRequiresRoot
