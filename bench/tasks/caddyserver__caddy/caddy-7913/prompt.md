## Context
Caddy's HTTP server has hard read and write timeouts that bound a whole transfer. A
slow client can defeat them from below (slowloris): it keeps trickling bytes, never
idle, so no hard deadline short enough to stop it is long enough for legitimate
large transfers. This task adds idle-based deadlines and rate floors, at the server
level and as a per-route handler.

## Requirement
- Add idle read and idle write timeouts: the deadline is reset on every successful
  read of the request body or write of the response, so a stalled connection is cut
  while a slow-but-progressing one survives. Existing hard timeouts keep their meaning
  and their unbounded default; when both are set, the idle-reset deadline must never
  push past the hard one.
- Add optional minimum transfer rates (bytes per second, 0 = disabled) for reading
  and writing: the allowed deadline grows from a fixed start according to bytes
  transferred, so a trickle that never stalls but never sustains the rate is still cut,
  while a transfer at or above the rate completes even if it exceeds the idle window.
- Large writes must be chunked so a single write or a `ReadFrom` fast path cannot
  exceed one deadline window: each underlying write covers at most a configurable
  chunk size (default 64 KiB), and the deadline is reset between chunks. The default
  chunk size is exposed as a package-level constant and can be overridden per
  configuration.
- The response-writer side wraps the handler chain's writer using the package's
  existing wrapper type and forwards deadlines through the standard response
  controller so HTTP/1.1, HTTP/2 and HTTP/3 all work.
- Server-wide configuration: JSON fields `read_idle_timeout`, `write_idle_timeout`,
  `read_min_rate`, `write_min_rate`, `max_write_chunk` on the server, and in the
  Caddyfile `timeouts` server option `read_body_idle`, `write_idle`, `write_max_chunk`.
  Idle timeouts default to 1 minute; rates default to 0.
- Per-route: a new handler module `http.handlers.timeouts` with a Caddyfile directive
  `timeouts`, ordered among the built-in directives, taking `read_timeout` and
  `write_timeout` (each with an optional minimum-rate second argument) and
  `write_max_chunk`; it applies the same idle-reset semantics to just its route.
- No behaviour change for existing configurations that set none of the new options.

## Constraints
- Go; no new module dependencies; follow the conventions of the surrounding code and
  register the new module the way sibling handlers are registered.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
The test files at `modules/caddyhttp/idletimeout_test.go` and
`modules/caddyhttp/timeouts/timeouts_test.go` were added to this checkout and
currently fail to compile. Make them pass without modifying them. `go test ./...` must
stay green.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
