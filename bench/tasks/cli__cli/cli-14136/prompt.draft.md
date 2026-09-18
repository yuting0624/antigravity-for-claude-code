# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #14136 Add worktree checkout to `gh issue develop` (merged 2026-08-21T15:11:54Z)

### Description

<!--
What's the problem? How are we addressing it?

Write for a reviewer who has not worked in this part of the codebase. Give them the
background they need before the problem makes sense, and avoid jargon.
-->

`gh issue develop --checkout` currently checks a linked development branch out in the caller's current working copy. This makes it difficult to start work on an issue without interrupting whatever branch is already checked out there.

This change adds `--worktree <path>` to `gh issue develop`. When it is combined with `--checkout`, the command creates the linked branch as usual but checks it out in a new Git worktree at the requested path. The original working copy remains on its current branch.

The implementation supports both checkout paths used by `issue develop`:

- If the linked branch does not exist locally, the command creates it in the new worktree as a tracking branch from the matching remote.
- If the linked branch already exists locally, the command adds a worktree for it and attempts the same fast-forward-only pull used by the existing checkout flow, scoped to the new worktree with `git -C`.

The remote is still selected from the linked branch repository, so `--branch-repo` works when the issue and development branch belong to different repositories. Relative worktree paths are normalized to absolute paths, and paths containing spaces are passed to Git as individual arguments.

The new flag requires `--checkout`, rejects an explicitly blank path, and is mutually exclusive with `--list`. Without `--worktree`, `gh issue develop` follows its existing checkout behavior.

A reusable `git.Client.AddWorktree` helper encapsulates the two supported Git operations:

```console
git worktree add -- <path> <existing-branch>
git worktree add --track -b <new-branch> -- <path> <remote>/<new-branch>
```

Acceptance scenarios cover same-repository and cross-repository worktree creation, both local branch states, `--name`, `--base`, relative paths containing spaces, flag validation, occupied targets, and unchanged traditional checkout behavior.

### How did you test this change?

<!--
Show how you exercised the change yourself, as a user of `gh` would.

Automated test results do not belong here. Passing unit tests, `go test ./...` output, and
coverage numbers tell a reviewer nothing they cannot see from CI, so do not paste them.

Use one or more of these, whichever communicates best:

1. Screenshots or GIFs of the real command running. Preferred whenever the change is visible
   in terminal output. If output changed, show it before and after.
2. Given/When/Then scenarios. For example:
   Given I am in a repo with no open pull requests
   When I run `gh pr list`
   Then I see "no open pull requests in cli/cli"
3. A natural language walkthrough of what you did by hand, the states you covered, and what
   you saw, including error and edge cases.

If you leave this empty, your pull request will very likely be closed.
-->

<details><summary>Flags</summary>
<p>
Testing gh issue develop --worktree flag validation

$ ../cli/bin/gh issue develop --help
Manage linked branches for an issue.

When using the `--base` flag, the new development branch will be created from the specified
remote branch. The new branch will be configured as the base branch for pull requests created using
`gh pr create`.


USAGE
  gh issue develop {<number> | <url>} [flags]

FLAGS
  -b, --base string          Name of the remote branch you want to make your new branch from
      --branch-repo string   Name or URL of the repository where you want to create your new branch
  -c, --checkout             Checkout the branch after creating it
  -l, --list                 List linked branches for the issue
  -n, --name string          Name of the branch to create
      --worktree path        Check out the branch into a worktree at the given path

INHERITED FLAGS
      --help                     Show help for command
  -R, --repo [HOST/]OWNER/REPO   Select another repository using the [HOST/]OWNER/REPO format

EXAMPLES
  # List branches for issue 123
  $ gh issue develop --list 123
  
  # List branches for issue 123 in repo cli/cli
  $ gh issue develop --list --repo cli/cli 123
  
  # Create a branch for issue 123 based on the my-feature branch
  $ gh issue develop 123 --base my-feature
  
  # Create a branch for issue 123 and check it out
  $ gh issue develop 123 --checkout
  
  # Create a branch for issue 123 and check it out in a worktree
  $ gh issue develop 123 --checkout --worktree /path/to/worktree
  
  # Create a branch in repo monalisa/cli for issue 123 in repo cli/cli
  $ gh issue develop 123 --repo cli/cli --branch-repo monalisa/cli

LEARN MORE
  Use `gh <command> <subcommand> --help` for more information about a command.
  Read the manual at https://cli.github.com/manual
  Learn about exit codes using `gh help exit-codes`
  Learn about accessibility experiences using `gh help accessibility`


$ ../cli/bin/gh issue develop 1 --repo sergiou87/test-repo --worktree ../unused-worktree
--worktree requires --checkout

Usage:  gh issue develop {<number> | <url>} [flags]

Flags:
  -b, --base string          Name of the remote branch you want to make your new branch from
      --branch-repo string   Name or URL of the repository where you want to create your new branch
  -c, --checkout             Checkout the branch after creating it
  -l, --list                 List linked branches for the issue
  -n, --name string          Name of the branch to create
      --worktree path        Check out the branch into a worktree at the given path
  
[exit status: 1]
PASS: rejected with expected error

$ ../cli/bin/gh issue develop 1 --repo sergiou87/test-repo --list --worktree ../unused-worktree
specify only one of `--list` or `--worktree`

Usage:  gh issue develop {<number> | <url>} [flags]

Flags:
  -b, --base string          Name of the remote branch you want to make your new branch from
      --branch-repo string   Name or URL of the repository where you want to create your new branch
  -c, --checkout             Checkout the branch after creating it
  -l, --list                 List linked branches for the issue
  -n, --name string          Name of the branch to create
      --worktree path        Check out the branch into a worktree at the given path
  
[exit status: 1]
PASS: rejected with expected error

$ ../cli/bin/gh issue develop 1 --repo sergiou87/test-repo --checkout --worktree ''
--worktree cannot be blank

Usage:  gh issue develop {<number> | <url>} [flags]

Flags:
  -b, --base string          Name of the remote branch you want to make your new branch from
      --branch-repo string   Name or URL of the repository where you want to create your new branch
  -c, --checkout             Checkout the branch after creating it
  -l, --list                 List linked branches for the issue
  -n, --name string          Name of the branch to create
      --worktree path        Check out the branch into a worktree at the given path
  
[exit status: 1]
PASS: rejected with expected error

$ git -C ../cli diff --exit-code trunk...HEAD -- docs share
PASS: command help contains new source documentation; generated docs are unchanged

=== Focused unit coverage ===

$ (cd ../cli && go test ./git -run \^TestClientAddWorktree\$)
ok  	github.com/cli/cli/v2/git	(cached)

$ (cd ../cli && go test ./pkg/cmd/issue/develop -run \^\(TestNewCmdDevelop\|TestDevelopRun\|TestCheckoutBranchWorktree\)\$)
ok  	github.com/cli/cli/v2/pkg/cmd/issue/develop	(cached)

All flag and help checks passed.
</p>
</details> 

<details><summary>Basic functionality</summary>
<p>
=== New local branch from remote; relative path with spaces ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-new --base main --checkout --worktree ../issue\ develop\ worktrees\ 20260813140601-15620/new\ branch
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-new
From https://github.com/sergiou87/test-repo
 * [new branch]      issue-develop-wt-20260813140601-15620-new -> origin/issue-develop-wt-20260813140601-15620-new

$ git branch --show-current
commit-msg-demo
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/new\ branch rev-parse --show-toplevel
/Users/sergiou87/Developer/GitHub/issue develop worktrees 20260813140601-15620/new branch
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/new\ branch branch --show-current
issue-develop-wt-20260813140601-15620-new
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/new\ branch rev-parse --abbrev-ref @\{upstream\}
origin/issue-develop-wt-20260813140601-15620-new
PASS

$ git config --get branch.issue-develop-wt-20260813140601-15620-new.gh-merge-base
main
PASS

$ git worktree list
/Users/sergiou87/Developer/GitHub/test-repo                                                78b771c [commit-msg-demo]
/Users/sergiou87/Developer/GitHub/issue develop worktrees 20260813140601-15620/new branch  076bfa3 [issue-develop-wt-20260813140601-15620-new]
PASS: caller checkout unchanged; absolute worktree uses named branch and tracks origin

=== Fresh-worktree scope; rerun delegates failure to git ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-new --checkout --worktree ../issue\ develop\ worktrees\ 20260813140601-15620/new\ branch
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-new
failed to run git: Preparing worktree (checking out 'issue-develop-wt-20260813140601-15620-new')
fatal: '/Users/sergiou87/Developer/GitHub/issue develop worktrees 20260813140601-15620/new branch' already exists
[exit status: 1]
PASS: git rejected target as expected

=== Existing local branch reused in a new worktree ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-existing --base main
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-existing
From https://github.com/sergiou87/test-repo
 * [new branch]      issue-develop-wt-20260813140601-15620-existing -> origin/issue-develop-wt-20260813140601-15620-existing

$ git branch --track issue-develop-wt-20260813140601-15620-existing origin/issue-develop-wt-20260813140601-15620-existing
branch 'issue-develop-wt-20260813140601-15620-existing' set up to track 'origin/issue-develop-wt-20260813140601-15620-existing'.

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-existing --base main --checkout --worktree ../issue\ develop\ worktrees\ 20260813140601-15620/existing\ branch
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-existing
From https://github.com/sergiou87/test-repo
 * branch            issue-develop-wt-20260813140601-15620-existing -> FETCH_HEAD
Already up to date.

$ git branch --show-current
commit-msg-demo
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/existing\ branch branch --show-current
issue-develop-wt-20260813140601-15620-existing
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/existing\ branch rev-parse --abbrev-ref @\{upstream\}
origin/issue-develop-wt-20260813140601-15620-existing
PASS

$ git config --get branch.issue-develop-wt-20260813140601-15620-existing.gh-merge-base
main
PASS
PASS: existing local branch checked out and fast-forwarded in worktree

=== Occupied path delegates failure to git ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-occupied --base main
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-occupied
From https://github.com/sergiou87/test-repo
 * [new branch]      issue-develop-wt-20260813140601-15620-occupied -> origin/issue-develop-wt-20260813140601-15620-occupied

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-occupied --checkout --worktree ../issue\ develop\ worktrees\ 20260813140601-15620/occupied\ path
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-occupied
failed to run git: Preparing worktree (new branch 'issue-develop-wt-20260813140601-15620-occupied')
fatal: '/Users/sergiou87/Developer/GitHub/issue develop worktrees 20260813140601-15620/occupied path' already exists
[exit status: 1]
PASS: git rejected target as expected

$ sed -n 1p ../issue\ develop\ worktrees\ 20260813140601-15620/occupied\ path/existing-file
do not overwrite
PASS

=== Existing behavior without --worktree, isolated in disposable clone ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-legacy --base main
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-legacy
From https://github.com/sergiou87/test-repo
 * [new branch]      issue-develop-wt-20260813140601-15620-legacy -> origin/issue-develop-wt-20260813140601-15620-legacy

$ git clone --no-local . ../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone
Cloning into '../issue develop worktrees 20260813140601-15620/legacy clone'...

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone remote set-url origin https://github.com/sergiou87/test-repo.git

$ (cd ../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone && env GH_PAGER=cat /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --name issue-develop-wt-20260813140601-15620-legacy --checkout)
github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-legacy
From https://github.com/sergiou87/test-repo
 * [new branch]      issue-develop-wt-20260813140601-15620-legacy -> origin/issue-develop-wt-20260813140601-15620-legacy

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone branch --show-current
issue-develop-wt-20260813140601-15620-legacy
PASS

$ git -C ../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone rev-parse --abbrev-ref @\{upstream\}
origin/issue-develop-wt-20260813140601-15620-legacy
PASS

$ sh -c git\ -C\ \"../issue\ develop\ worktrees\ 20260813140601-15620/legacy\ clone\"\ worktree\ list\ --porcelain\ \|\ grep\ -c\ \'\^worktree\ \'
1
PASS
PASS: no-worktree checkout still switches checkout and creates no extra worktree

=== Linked branches created during test ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --list
issue-develop-wt-20260813140601-15620-new	https://github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-new
issue-develop-wt-20260813140601-15620-existing	https://github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-existing
issue-develop-wt-20260813140601-15620-occupied	https://github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-occupied
issue-develop-wt-20260813140601-15620-legacy	https://github.com/sergiou87/test-repo/tree/issue-develop-wt-20260813140601-15620-legacy

$ git branch --show-current
commit-msg-demo
PASS

PASS: all live same-repository scenarios passed; caller branch and status unchanged.
</p>
</details> 

<details><summary>Cross-repo support</summary>
<p>
Issue repository: sergiou87/test-repo
Branch repository: sergiou87-org/test-repo
Branch repository base: main

$ git remote add issue-develop-cross-20260813144150-88754 https://github.com/sergiou87-org/test-repo.git

$ git remote -v
issue-develop-cross-20260813144150-88754	https://github.com/sergiou87-org/test-repo.git (fetch)
issue-develop-cross-20260813144150-88754	https://github.com/sergiou87-org/test-repo.git (push)
origin	https://github.com/sergiou87/test-repo.git (fetch)
origin	https://github.com/sergiou87/test-repo.git (push)

=== Cross-repository worktree checkout ===

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --branch-repo sergiou87-org/test-repo --name issue-develop-wt-20260813144150-88754-cross-repo --base main --checkout --worktree ../issue\ develop\ cross\ repo\ 20260813144150-88754/cross\ repo\ branch
github.com/sergiou87-org/test-repo/tree/issue-develop-wt-20260813144150-88754-cross-repo
From https://github.com/sergiou87-org/test-repo
 * [new branch]      issue-develop-wt-20260813144150-88754-cross-repo -> issue-develop-cross-20260813144150-88754/issue-develop-wt-20260813144150-88754-cross-repo

$ git branch --show-current
commit-msg-demo
PASS

$ git -C ../issue\ develop\ cross\ repo\ 20260813144150-88754/cross\ repo\ branch rev-parse --show-toplevel
/Users/sergiou87/Developer/GitHub/issue develop cross repo 20260813144150-88754/cross repo branch
PASS

$ git -C ../issue\ develop\ cross\ repo\ 20260813144150-88754/cross\ repo\ branch branch --show-current
issue-develop-wt-20260813144150-88754-cross-repo
PASS

$ git -C ../issue\ develop\ cross\ repo\ 20260813144150-88754/cross\ repo\ branch rev-parse --abbrev-ref @\{upstream\}
issue-develop-cross-20260813144150-88754/issue-develop-wt-20260813144150-88754-cross-repo
PASS

$ git config --get branch.issue-develop-wt-20260813144150-88754-cross-repo.gh-merge-base
main
PASS

$ git remote get-url issue-develop-cross-20260813144150-88754
https://github.com/sergiou87-org/test-repo.git
PASS

$ git worktree list
/Users/sergiou87/Developer/GitHub/test-repo                                                        78b771c [commit-msg-demo]
/Users/sergiou87/Developer/GitHub/issue develop cross repo 20260813144150-88754/cross repo branch  076bfa3 [issue-develop-wt-20260813144150-88754-cross-repo]

$ /Users/sergiou87/Developer/GitHub/cli/bin/gh issue develop 1 --repo sergiou87/test-repo --list
issue-develop-wt-20260813144150-88754-cross-repo	https://github.com/sergiou87-org/test-repo/tree/issue-develop-wt-20260813144150-88754-cross-repo

PASS: cross-repo branch tracks remote matching --branch-repo; caller checkout unchanged.
</p>
</details> 

### Key points

<!--
Tradeoffs you accepted, alternatives you rejected, and anything a reviewer would otherwise have to guess at.
-->

- This change creates fresh worktrees only. It does not attempt to detect or reuse an existing worktree at the requested path. Occupied paths and branches already checked out elsewhere are delegated to Git so users receive native `git worktree add` errors.
- The broader `gh pr checkout --worktree` implementation includes reuse, force, and detached-HEAD behavior. Refactoring that state machine was intentionally avoided because `issue develop` only needs the two fresh-worktree operations described above.
- Existing local branches retain the current warning-only behavior when they cannot be fast-forwarded. The pull runs inside the newly added worktree rather than the caller's working copy.
- The command source remains the documentation authority; the new flag and example will flow into generated command documentation.

### Notes for reviewers

<!--
Where should review start, and what should be read next? Call out anything you are unsure about.

Link related issues or prior discussion, with one sentence on why each matters.
-->

Start with `checkoutBranch` in `pkg/cmd/issue/develop/develop.go`, which contains the behavior split between traditional checkout and worktree checkout. Then review `git.Client.AddWorktree` in `git/client.go` for the exact Git argument forms.

The command-constructor tests cover flag curation and validation, while the checkout tests cover existing and missing local branches, cross-repository remote selection, paths containing spaces, and Git error propagation.

### Authorship and follow-up

<!--
REQUIRED - If you are an AI agent filling in this template, answer "Who wrote this" for yourself and answer honestly. For "Who answers review comments," use only a choice the human has explicitly made in the conversation. If no choice has already been established, pause and ask the human to choose one of the three options before creating or updating the pull request. Do not infer the choice from repository ownership, authorship, assignees, prior interactions, or the current operator. After the human answers, check exactly the option they chose; the last option is valid when the human explicitly chooses nobody.

Check exactly one box in each list.
-->

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @sergiou87 will read and reply directly.
- [ ] An agent will draft replies and @username will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## Files (code)

- pkg/cmd/issue/develop/develop.go
- pkg/cmd/pr/checkout/checkout.go
- pkg/cmd/pr/shared/worktree.go

## Hidden tests

- acceptance/testdata/issue/issue-develop-worktree-cross-repo.txtar
- acceptance/testdata/issue/issue-develop-worktree.txtar
- pkg/cmd/issue/develop/develop_test.go
- pkg/cmd/pr/checkout/checkout_test.go
- pkg/cmd/pr/shared/worktree_test.go

## Test functions

- TestDevelopRun
- TestNewCmdCheckout
- TestNewCmdDevelop
- TestPRCheckout_detach
- TestPRCheckout_detachedHead
- TestPRCheckout_differentRepo
- TestPRCheckout_differentRepoForce
- TestPRCheckout_differentRepo_currentBranch
- TestPRCheckout_differentRepo_existingBranch
- TestPRCheckout_differentRepo_invalidBranchName
- TestPRCheckout_differentRepo_remoteExists
- TestPRCheckout_existingBranch
- TestPRCheckout_force
- TestPRCheckout_maintainerCanModify
- TestPRCheckout_recurseSubmodules
- TestPRCheckout_sameRepo
- TestPromptingPRResolver
- TestResolveWorktreeTarget
- TestResolveWorktreeTargetPathSafety
- TestSpecificPRResolver
- TestWorktreeCheckoutCommands
- Test_authenticatedCommand_stripsWorktreePrefix
- Test_checkoutRun
