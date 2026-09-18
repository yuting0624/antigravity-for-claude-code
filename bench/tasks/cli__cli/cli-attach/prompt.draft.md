# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #14177 `--attach` stack 1/8: Report what kind of token is active (merged 2026-08-25T21:29:54Z)

Part of the pull request stack tracked in #14186.

### Description

This is the first layer of an eight part stack. The full stack adds an `--attach` flag to six issue and pull request commands. The flag uploads a local media file to GitHub and puts it into the markdown body. If the text already references the local path, `gh` rewrites that path to point at the uploaded asset. Otherwise `gh` appends the file at the end.

This pull request does not change anything a user can see. It adds two things the upper layers need.

The upload endpoint only accepts some kinds of credential. The first commit adds a token type to the `gh` package and a method on the auth config that reports what kind of credential is active for a host, told by the token prefix. A caller can decide whether a credential will work without ever reading the token into memory or passing it around.

The upload endpoint also needs the repository's numeric REST id, and `gh` checks the user's role on the repository before uploading anything. Neither was selected before. The second commit selects both on issues, on pull requests, and on a plain repository lookup, and adds accessors that return zero values when the caller did not request the repository field.

### How did you test this change?

The whole stack was built and exercised by hand. For this layer specifically, `gh pr view --json headRepository` was run against the built binary and against a build of trunk, and the output was byte identical.

That is the regression this shape is designed to avoid. The pull request type reuses one Go struct for both the repository and the head repository.

### Key points

Asking the config for a token kind rather than for the token keeps credentials out of command code. No command in this stack ever handles a token in order to attach a file.

The accessors return zero values rather than an error when the repository field was not requested, because that field is optional in the queries.

The new fields on the shared struct are omitted when empty, and a test row fails if the head repository output ever starts carrying them.

### Notes for reviewers

A note in the code records three other places in `gh` that read a token and match its prefix by hand. Those are `gh auth status`, the check for whether an auth token is writeable, and agent-task. Moving them is not part of this stack.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14178 `--attach` stack 2/8: Describe and validate a file `gh` can attach (merged 2026-08-25T21:29:55Z)

Part of the pull request stack tracked in #14186.

### Description

This is the second layer of the stack. It adds an internal package for attachments, holding the rules about what a file is and whether `gh` will accept it. Nothing here is reachable from a command yet.

Nine file extensions are accepted. Six are images: png, jpg, jpeg, gif, webp and svg. Three are videos: mp4, mov and webm. Each maps to the content type the upload endpoint expects. The extension is the only thing checked, and it is matched without regard to case.

An image and a video are separate types, because GitHub renders them differently. An image becomes a markdown image embed. A video becomes a bare URL on its own line, which is what GitHub needs in order to show a player. A video has no alt text in that form, so asking for alt text on a video is refused rather than quietly ignored.

Validation reads the file's metadata and never opens the file. It refuses a path that does not exist, a directory, anything that is not a regular file, and an empty file.

### How did you test this change?

The whole stack was built and every one of the nine accepted types was uploaded to a private test repository and downloaded again. The content type sent matched the content type served back in every case, and the bytes were identical in every case. The six image types produced image embeds and the three video types produced bare URLs.

Refusals were exercised by hand as well: an unsupported file type, an image over the size limit, a directory, a missing file, an empty file, and alt text on a video. In each case the command exited with an error and uploaded nothing.

### Key points

Deciding by extension rather than by content is deliberate. The question being asked is how GitHub will render the file, not what the bytes are, and the endpoint accepts mislabelled bytes anyway.

Images are refused over 10 MB and videos over 100 MB. `gh` cannot know the real video limit, because it depends on the account plan. The local limit only catches what could never succeed, and the server reports the rest.

The image and video split lives in the type system rather than in conditionals spread around the package, because the two really do render differently and almost every rule downstream depends on which one it is.

### Notes for reviewers

Nothing in this pull request is reachable from a command. The flag that reaches it arrives further up the stack.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14179 `--attach` stack 3/8: Rewrite markdown references to uploaded assets (merged 2026-08-25T21:29:56Z)

Part of the pull request stack tracked in #14186.

### Description

This is the third layer of the stack, and the largest and hardest pull request in it. Nothing here is reachable from a command yet.

Given some markdown and a set of attached files, it finds every reference in the markdown that points at one of those files and rewrites the destination to the uploaded URL. It reports which attachments were never referenced, so the caller can append them.

The code runs in three phases, and it is ordered that way on purpose:

1. Find every reference. The markdown is parsed with goldmark, the parser `gh` already depends on, and each link or image node is asked for its position.
2. Plan the edits. Each reference becomes a byte range and a replacement.
3. Apply the edits, working back to front so the earlier ranges stay valid.

The behaviour that follows from that:

- A reference style definition is rewritten once, at the definition, so every use of that label follows from one edit.
- A path inside a code fence or an inline code span is left exactly as written.
- A plain link stays a link. Only the destination moves, so alt text, titles and formatting inside the label survive.
- A video embedded alone on its own line has the whole node replaced by a bare URL, because that is what GitHub needs to render a player. A video embedded inline degrades to a link instead, since a player cannot render in the middle of a sentence.
- A video written as a reference style image is refused, because rewriting it would produce an image tag pointing at a video.
- The same file referenced twice is uploaded once and both references get the same URL.

The second commit adds one markdown document that exercises every syntax the package handles, together with its expected output.

### How did you test this change?

The whole stack was built and each of the behaviours above was exercised by hand against a private test repository. That covered a reference rewritten in place, a reference style definition with two uses following one edit, a fenced block and an inline code span left untouched, a plain link staying a link, a video alone on a line becoming a bare URL, a video inline becoming a link, a video as a reference style image being refused, an unused definition left alone, a file named in the body but never attached left alone, and the same file referenced twice sharing one uploaded asset.

### Key points

About 110 lines of this are hand written byte scanning. It exists because goldmark reports the position of a node but not the position of the destination inside that node.

The alternative would be to re-render the document from the parsed tree. That would be worse, because it normalises the author's own prose, and someone who wrote a comment by hand should get their comment back rather than a reformatted version of it. A follow up can restructure this around goldmark's node identity and delete some of the scanning. That work is not here.

### Notes for reviewers

Start with the two entry points and read the three phases in order.

The fixture document in the second commit is the fastest way to understand the behaviour. Reading the input and the expected output side by side shows what the package does without reading the scanner at all, which is why it is a separate commit.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14180 `--attach` stack 4/8: Upload an asset to GitHub (merged 2026-08-25T21:29:57Z)

Part of the pull request stack tracked in #14186.

### Description

This is the fourth layer of the stack. It adds the uploader that posts a file to GitHub's user attachments endpoint and returns the asset URL, plus a small helper that builds the upload host for a given GitHub host. Nothing here is reachable from a command yet.

Three refusals happen before any request is made, in this order:

1. GitHub Enterprise Server, because the endpoint does not exist there.
2. A kind of credential the endpoint will not accept.
3. A role on the repository below write.

The host is checked first on purpose. On an enterprise server no token and no permission would ever make an upload work, so any other order would name a fault the user cannot fix.

### How did you test this change?

The whole stack was built and files were uploaded to a private test repository from two accounts. One had write access and every upload succeeded. One had read only access, and every command refused before any request left the machine, which was confirmed by counting the requests rather than by trusting the message.

The upload host was also checked against a GitHub Enterprise Cloud tenant host, where it derives from the target host correctly.

### Key points

The uploader never stores the token. It is told what kind of credential is active and nothing more, and the credential actually sent is chosen by the transport from the request host, like all `gh` requests.

The upload host is derived from the target host, so a tenant with data residency uploads to its own host rather than to github.com.

Refusing early matters more here than in most places, because an upload cannot be undone.

### Notes for reviewers

Read the three refusals first, and the reason the host is checked before the rest.

A note in the code explains why the request is built by hand rather than through the usual REST client. The endpoint requires both a content type and a content length on every request, and the shared client sets neither.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14181 `--attach` stack 5/8: Add the flag and upload behind it (merged 2026-08-25T21:29:58Z)

Part of the pull request stack tracked in #14186.

### Description

This is the fifth layer of the stack. The first commit adds the flag and reads its values. The second ties uploading to rewriting and decides when the resulting markdown is safe to write. No command offers the flag yet.

The flag is repeatable and takes a file path, optionally followed by `#` and alt text. Without alt text the file name is used. Every named file is validated before anything is uploaded.

Naming the same file twice is refused, and that includes a file and a symlink to it, and a file and a hard link to it, since both would upload the same bytes twice. An empty value is refused too, which is what a script produces when a variable is unset.

Conflicting flags are checked while the flag is being read, rather than in each command, so a command that offers the flag cannot forget to check them.

The flag is registered as a string array rather than a string slice, because a string slice splits on commas and a comma is legal in a file name:

```go
cmd.Flags().StringArray(flagName, nil, "Attach an image or video `file`, in <file>#<alt text> format")
```

### How did you test this change?

The whole stack was built and the failure path was exercised by hand against a private test repository. Three files were attached with the middle one made unreadable. Exactly one upload request left the machine for three attached files, the command exited non zero and named the file that failed, and the comment was still posted carrying the one file that did upload.

When the only attached file failed, nothing was posted at all and the command said so.

Duplicate detection was exercised with a plain duplicate, with a symlink to the same file, and with a hard link to it.

### Key points

An upload cannot be undone and there is no endpoint to delete an uploaded asset. That single fact drives the design of the second commit.

The function reports how many assets reached the server, and a caller writes the body only when that count is above zero. Markdown that does not reference an uploaded asset would orphan that asset for good. A count of zero means nothing was uploaded, so nothing is lost by writing nothing.

Uploading stops at the first failure and nothing after it is attempted. A reference to a file that did not upload keeps its local path, so a partial failure leaves a body containing links that do not resolve. That is the accepted cost of writing a body that already carries a real uploaded asset, and it is a thing a user will see.

### Notes for reviewers

The count returned by the upload function is the whole safety mechanism. Read that first, then read the callers in the layers above to see how it is used.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14182 `--attach` stack 6/8: Add the flag to gh pr comment and gh issue comment (merged 2026-08-25T21:29:59Z)

Part of the pull request stack tracked in #14186.

### Description

This is the sixth layer of the stack, and the first one where a user can do anything. It adds `--attach` to `gh pr comment` and `gh issue comment`.

The flag uploads a local image or video and puts it in the comment. If the comment body already references the local path, that reference is rewritten to the uploaded asset URL. Otherwise the file is appended at the end. Alt text goes after a `#`, and without it the file name is used.

```
gh issue comment 12 --attach './login.png#The login error state'
```

An image becomes a markdown image embed. A video becomes a bare URL on its own line, which is what GitHub needs to show a player.

An attachment counts as body input on its own, so `--attach` with no `--body` posts a comment that is just the image.

With `--edit-last`, attaching a file keeps the text of the comment being edited and adds the attachment below it. An attachment is not a body, so it does not replace one.

Two combinations are refused. `--attach` with `--web` cannot work, because the browser is doing the writing. `--attach` with `--delete-last` is refused as well.

### How did you test this change?

Both commands were exercised by hand against a private test repository. That covered a comment with an image, a comment with a video, attaching with no body at all, alt text after the hash, a body whose reference was rewritten in place, a fenced code block left untouched, two files in one command, `--edit-last` keeping the existing text, `--edit-last` where the existing comment already named the file so the reference was rewritten instead of appended, and both refused flag combinations.

Everything was run again from a second account with read only access on the repository. Every attach was refused before any upload, and a plain comment with no attachment still worked, so only the attaching is blocked rather than the command.

### Key points

Resolving the flag happens in the shared comment code rather than in each command, so a command that offers the flag cannot forget to check it.

### Notes for reviewers

This is one commit covering two commands, which is worth explaining. Both commands run through the same shared comment code, and that shared code now resolves the flag for whichever command is running. It reports an error if the command has not registered the flag. So the shared change and both registrations have to land together; splitting them would leave whichever command was not wired yet broken.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14183 `--attach` stack 7/8: Add the flag to gh pr create and gh pr edit (merged 2026-08-25T21:30:00Z)

Part of the pull request stack tracked in #14186.

### Description

This is the seventh layer of the stack. It adds `--attach` to `gh pr create` and `gh pr edit`, one commit each.

```
gh pr create --title "Fix the login screen" --attach ./after.png
```

On create, the body can come from `--body`, from `--body-file`, from standard input, from a text editor, or from `--fill`, which builds the body from the commits. All of them work with an attachment, and a reference written in any of them is rewritten in place.

On edit, using only `--attach` with no body flag keeps the existing body and adds the attachment below it. If the existing body already references the file, the reference is rewritten in place and nothing is appended.

Two combinations are refused on create. `--attach` with `--web` cannot work. `--attach` with `--dry-run` is refused because a dry run should not upload anything, and an upload cannot be undone.

### How did you test this change?

Both commands were exercised by hand against a private test repository. That covered a pull request created with an image, one created with a video, one created from a body file whose reference was rewritten, and one created with `--fill` where the generated body was kept and the asset appended below it rather than replacing it.

On edit it covered appending to an existing body, and editing where the reference already in the body was rewritten in place. Both refused flag combinations were checked.

A failed rewrite was also exercised. A body that embeds a video through a reference style definition cannot be rewritten, and in that case the command exited non zero, the existing body was left exactly as it was, and nothing was printed to standard output.

### Key points

The failure case is the one worth reading closely. When the markdown cannot be rewritten, the existing body survives untouched and no URL is printed, so the run does not read as a success to a script.

### Notes for reviewers

The two commits are independent and can be read in either order. Editing is the more interesting of the two, because it has an existing body to preserve and creating does not.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## PR #14184 `--attach` stack 8/8: Add the flag to gh issue create and gh issue edit (merged 2026-08-25T21:30:01Z)

Part of the pull request stack tracked in #14186.

### Description

This is the top of the stack. It adds `--attach` to `gh issue create` and `gh issue edit`, one commit each.

```
gh issue edit 12 --attach ./repro.png
```

On create the body can come from `--body`, from `--body-file`, from standard input, or from a text editor. A reference written in the editor is rewritten exactly like one passed by flag. `--attach` with `--web` is refused.

On edit, using only `--attach` keeps the existing body and appends the file below it, and a reference already in the body is rewritten in place instead.

Editing more than one issue at once with `--attach` is refused, since one upload would have to be shared across several bodies.

### How did you test this change?

Both commands were exercised by hand against a private test repository. That covered an issue created with an image, one created with a video, one created from a body file, and one created through the editor where the reference in the editor text was rewritten in place.

On edit it covered appending to an existing body, and editing where the reference already in the body was rewritten. Both refused flag combinations were checked.

### Key points

The editor path is worth knowing about. The body a user types into their editor is treated the same as one passed on the command line, so a reference written there is rewritten too.

### Notes for reviewers

With this merged the flag is available on all six commands: `gh issue comment`, `gh pr comment`, `gh issue create`, `gh pr create`, `gh issue edit` and `gh pr edit`.

### Authorship and follow-up

Who wrote this:

- [ ] A human wrote it.
- [x] An agent wrote it under close human direction.
- [ ] An agent wrote it independently, and no human has guided the implementation beyond the initial prompt.

Who answers review comments:

- [x] @BagToad will read and reply directly. Name the account.
- [ ] An agent will draft replies and @BagToad will read them before they are posted.
- [ ] Nobody has explicitly committed to replying.


## Files (code)

- api/queries_issue.go
- api/queries_pr.go
- api/queries_repo.go
- api/query_builder.go
- internal/attachments/attach.go
- internal/attachments/client.go
- internal/attachments/doc.go
- internal/attachments/flags.go
- internal/attachments/references.go
- internal/attachments/test.go
- internal/attachments/userasset.go
- internal/config/config.go
- internal/gh/gh.go
- internal/ghinstance/host.go
- pkg/cmd/issue/comment/comment.go
- pkg/cmd/issue/create/create.go
- pkg/cmd/issue/edit/edit.go
- pkg/cmd/pr/comment/comment.go
- pkg/cmd/pr/create/create.go
- pkg/cmd/pr/edit/edit.go
- pkg/cmd/pr/shared/commentable.go
- pkg/httpmock/legacy.go

## Hidden tests

- api/export_pr_test.go
- api/queries_issue_test.go
- api/queries_pr_test.go
- api/queries_repo_test.go
- api/query_builder_test.go
- internal/attachments/attach_test.go
- internal/attachments/client_test.go
- internal/attachments/flags_test.go
- internal/attachments/references_fixture_test.go
- internal/attachments/references_test.go
- internal/attachments/testdata/references_expected.md
- internal/attachments/testdata/references_input.md
- internal/attachments/userasset_test.go
- internal/config/auth_config_test.go
- internal/ghinstance/host_test.go
- pkg/cmd/issue/comment/comment_test.go
- pkg/cmd/issue/create/create_test.go
- pkg/cmd/issue/edit/edit_test.go
- pkg/cmd/pr/comment/comment_test.go
- pkg/cmd/pr/create/create_test.go
- pkg/cmd/pr/edit/edit_test.go
- pkg/cmd/pr/shared/commentable_test.go

## Test functions

- TestActiveTokenType
- TestActorDisplayName
- TestAddFlag
- TestApiActorsSupported
- TestAppendParagraph
- TestAssetMarkdown
- TestAssetRendersAsPlayer
- TestAttachAssetsToMarkdown
- TestAttachAssetsToMarkdownFixture
- TestBaseRepoQueriesSelectDatabaseID
- TestBranchDeleteRemote
- TestCategorizeHost
- TestCheckHost
- TestCommentablePreRun
- TestCommentableRunUploadsAndWritesBodies
- TestDefaultHostFromEnvVar
- TestDefaultHostLoggedInToOnlyOneHost
- TestDefaultHostNotLoggedIn
- TestDefaultHostWorksRightAfterMigration
- TestDisplayName
- TestFlagUserAssets
- TestForkRepoReturnsErrorWhenForkIsNotPossible
- TestGitHubRepo_notFound
- TestGitHubRepo_success
- TestGitHubRepo_withParent
- TestGitIgnoreTemplateReturnsErrorWhenGitIgnoreTemplateNotFound
- TestGitIgnoreTemplateReturnsGitIgnoreTemplate
- TestGitProtocolWorksRightAfterMigration
- TestGraphQLEndpoint
- TestHasActiveToken
- TestHasEnvTokenWithEnvToken
- TestHasEnvTokenWithNoEnvTokenButAConfigVar
- TestHasEnvTokenWithoutAnyEnvToken
- TestHasNoActiveToken
- TestHostnameValidator
- TestHostsIncludesEnvVar
- TestHostsWorksRightAfterMigration
- TestIsSingleImage
- TestIssueCreate
- TestIssueCreate_AtCopilotAssignee
- TestIssueCreate_AtMeAssignee
- TestIssueCreate_continueInBrowser
- TestIssueCreate_disabledIssues
- TestIssueCreate_metadata
- TestIssueCreate_nonLegacyTemplate
- TestIssueCreate_projectsV2
- TestIssueCreate_recover
- TestIssueGraphQL
- TestIssueRepoInfo_issuesDisabled
- TestIssueRepoInfo_notFound
- TestIssueRepoInfo_success
- TestIssueRepositoryDatabaseID
- TestIssueRepositoryViewerPermission
- TestIssue_ExportData
- TestLicenseTemplateReturnsErrorWhenLicenseTemplateNotFound
- TestLicenseTemplateReturnsLicense
- TestListGitIgnoreTemplatesReturnsGitIgnoreTemplates
- TestListLicenseTemplatesReturnsLicenses
- TestLoginAddsHostIfNotAlreadyAdded
- TestLoginAddsUserToConfigWithoutGitProtocolAndWithSecureStorage
- TestLoginInsecurePostMigrationUsesConfigForToken
- TestLoginInsecureStorage
- TestLoginPostMigrationSetsGitProtocol
- TestLoginPostMigrationSetsUser
- TestLoginSecurePostMigrationRemovesTokenFromConfig
- TestLoginSecureStorageRemovesOldInsecureConfigToken
- TestLoginSecureStorageUsesKeyring
- TestLoginSecureStorageWithErrorFallsbackAndReports
- TestLoginSetsGitProtocolForProvidedHost
- TestLoginSetsUserForProvidedHost
- TestLogoutIgnoresErrorsFromConfigAndKeyring
- TestLogoutOfActiveUserSwitchesUserIfPossible
- TestLogoutOfInactiveUserDoesNotSwitchUser
- TestLogoutRemovesHostAndKeyringToken
- TestLogoutRightAfterMigrationRemovesHost
- TestMembersToIDs
- TestNewAsset
- TestNewAssetMissingFile
- TestNewAttachableMarkdown
- TestNewCmdComment
- TestNewCmdCreate
- TestNewCmdEdit
- TestNewUploader
- TestNoRepoCanBeDetermined
- TestPRRepositorySelectionMatchesStruct
- TestProjectsV1Deprecation
- TestPullRequestGraphQL
- TestPullRequestRepositoryDatabaseID
- TestPullRequestRepositoryViewerPermission
- TestPullRequest_ExportData
- TestRESTPrefix
- TestRemoteGuessing
- TestRepoExists
- TestRepoNetworkUnmarshalsDatabaseID
- TestSuggestedReviewerActors
- TestSuggestedReviewerActorsForRepo
- TestSwitchClearsActiveInsecureTokenWhenSwitchingToSecureUser
- TestSwitchClearsActiveSecureTokenWhenSwitchingToInsecureUser
- TestSwitchUserErrorsAndRestoresUserAndInsecureConfigUnderFailure
- TestSwitchUserErrorsAndRestoresUserAndKeyringUnderFailure
- TestSwitchUserErrorsImmediatelyIfTheActiveTokenComesFromEnvironment
- TestSwitchUserMakesInsecureTokenActive
- TestSwitchUserMakesSecureTokenActive
- TestSwitchUserUpdatesTheActiveUser
- TestTenantName
- TestTokenForUserInsecureLogin
- TestTokenForUserNotFoundErrors
- TestTokenForUserSecureLogin
- TestTokenFromKeyring
- TestTokenFromKeyringForUser
- TestTokenFromKeyringForUserErrorsIfUsernameIsBlank
- TestTokenFromKeyringNonExistent
- TestTokenPrioritizesActiveUserToken
- TestTokenStoredInConfig
- TestTokenStoredInEnv
- TestTokenStoredInKeyring
- TestTokenWithActiveUserNotInKeyringFallsBackToBlank
- TestTokenWorksRightAfterMigration
- TestUpload
- TestUploadAuthentication
- TestUploadErrors
- TestUploadHostForTenant
- TestUploadMissingFile
- TestUploaderUploadAndAttach
- TestUploaderUploadAndAttachAbsolutePathReference
- TestUploaderUploadAndAttachDoesNotLeakTheAssetURLIntoAnError
- TestUploaderUploadAndAttachNoAssets
- TestUploaderUploadAndAttachUploadsOnceForRepeatedReferences
- TestUserAssetUploadPrefix
- TestUserNotLoggedIn
- TestUserWorksRightAfterMigration
- TestUsersForHostNoHost
- TestUsersForHostWithUsers
- Test_Logins
- Test_ProjectNamesToPaths
- Test_RepoMetadata
- Test_RepoMetadata_TeamsAreConditionallyFetched
- Test_RepoMilestones
- Test_commentRun
- Test_createRun
- Test_createRun_GHES
- Test_editRun
- Test_editRun_crossHostRelationshipRefs
- Test_generateCompareURL
- Test_isSameRef
