## Context
`gh` (the GitHub CLI) lets users create and edit issues and pull requests and post
comments on them. Today a screenshot or a screen recording can only be attached by
pasting it into the web UI. This task adds an `--attach` flag that uploads a local image
or video to GitHub's user-attachments endpoint and puts it into the markdown body.

## Requirement
- The auth configuration reports what kind of credential is active for a host (the
  upload endpoint only accepts some kinds), and pull-request and repository queries also
  select the repository's numeric REST id and the viewer's role on it.
- An internal attachments package decides what `gh` will attach: nine extensions —
  images png, jpg, jpeg, gif, webp, svg (markdown image embed) and videos mp4, mov, webm
  (bare URL on its own line) — each mapped to its content type; images over 10 MB and
  videos over 100 MB are refused; a missing path, a directory, a non-regular or empty
  file is refused; validation reads metadata only. Alt text is allowed for images only.
- Given markdown and a set of attached files, every link or image reference to one of
  those files is rewritten to the uploaded URL (parsed with goldmark, which `gh` already
  uses): a reference-style definition is rewritten once at its definition; anything inside
  a code fence or inline code is left as written; a plain link stays a link with only its
  destination moved; attachments never referenced are reported so they can be appended.
- An uploader posts a file to the user-attachments endpoint and returns the asset URL,
  refusing in this order before any request: GitHub Enterprise Server, an unaccepted
  credential kind, a repository role below write; a helper derives the upload host.
- The flag is repeatable, takes `<file>` or `<file>#<alt text>` (file name as default alt
  text), is a string array (commas are legal in names), refuses the same file twice
  (including via symlink or hard link) and an empty value; all files are validated before
  any upload; if one upload fails nothing is written.
- Wire `--attach` into `gh issue comment`, `gh pr comment`, `gh pr create`, `gh pr edit`,
  `gh issue create` and `gh issue edit`: a body may come from `--body`, `--body-file`,
  stdin, the editor or `--fill`; a referenced path is rewritten in place, an unreferenced
  file is appended below the body; `--attach` alone counts as body input; on edit with
  only `--attach` the existing body stays and the file is appended; `--edit-last` keeps
  the comment text. Refused: `--attach` with `--web`, with `--delete-last`, with
  `--dry-run`, and editing several issues at once.
- Help text documents the flag; the HTTP mock package supports what the tests need.

## Constraints
- Go; no new module dependencies; follow the conventions of the surrounding command
  packages and of the existing internal packages; keep exported behaviour compatible.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
These test files were added or updated in this checkout and currently fail; make them
pass without modifying them and keep `go test ./...` green (the `acceptance/` package is
not part of the suite here): `api/export_pr_test.go`, `api/queries_issue_test.go`,
`api/queries_pr_test.go`, `api/queries_repo_test.go`, `api/query_builder_test.go`,
`internal/attachments/attach_test.go`, `internal/attachments/client_test.go`,
`internal/attachments/flags_test.go`, `internal/attachments/references_fixture_test.go`,
`internal/attachments/references_test.go`, `internal/attachments/userasset_test.go`,
`internal/attachments/testdata/references_input.md`,
`internal/attachments/testdata/references_expected.md`,
`internal/config/auth_config_test.go`, `internal/ghinstance/host_test.go`,
`pkg/cmd/issue/comment/comment_test.go`, `pkg/cmd/issue/create/create_test.go`,
`pkg/cmd/issue/edit/edit_test.go`, `pkg/cmd/pr/comment/comment_test.go`,
`pkg/cmd/pr/create/create_test.go`, `pkg/cmd/pr/edit/edit_test.go`,
`pkg/cmd/pr/shared/commentable_test.go`.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
