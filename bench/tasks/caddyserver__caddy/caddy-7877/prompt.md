## Context
Caddy's HTTP rewrite handler can strip a prefix or a suffix from the request path
(`uri strip_prefix` / `uri strip_suffix` in the Caddyfile, `strip_path_prefix` /
`strip_path_suffix` in JSON). Both operations are documented to compare in
normalized (unescaped) space, except where the configured pattern itself contains a
`%xx` escape, in which case that escape must match literally.

## Requirement
- Suffix stripping must honour that documented contract exactly as prefix stripping
  already does; today it silently fails whenever the path contains percent-encoding.
- A decoded suffix pattern must match a percent-encoded path: stripping `/b/c` from
  `/a/b%2Fc` yields `/a`; stripping `bc` from `/a%62c` yields `/a`.
- An escaped suffix pattern must still require the same escape in the path: stripping
  `%2fsuffix` from `/foo/bar/suffix` must leave the path unchanged.
- Comparison stays case-insensitive for the hex digits of an escape and otherwise
  behaves like the existing prefix comparison; a suffix that does not match leaves
  the path untouched.
- Both the decoded path and the raw (escaped) path of the request must be updated
  consistently, as the prefix case already does.
- No change to prefix stripping, query handling, or any other rewrite operation.

## Constraints
- Go; no new module dependencies; keep the existing behaviour for every case that
  already worked; follow the conventions of the surrounding code.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
The test file at `modules/caddyhttp/rewrite/rewrite_test.go` was updated in this
checkout and currently fails. Make it pass without modifying it. `go test ./...`
must stay green.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
