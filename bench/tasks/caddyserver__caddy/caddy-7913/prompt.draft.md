# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #7913 caddyhttp: mitigate slowloris via idle read/write deadlines (merged 2026-08-22T03:17:26Z)

## Summary

Adds `ReadIdleTimeout`/`WriteIdleTimeout` (`read_idle_timeout`/`write_idle_timeout` in JSON, `read_body_idle`/`write_idle` in the Caddyfile `timeouts` block), reset on every successful read/write via `http.ResponseController`. A stalled connection is killed; a slow-but-progressing one isn't — matching nginx's `client_body_timeout`/`send_timeout` semantics.

The existing `ReadTimeout`/`WriteTimeout` fields are untouched: same hard-deadline-over-the-whole-transfer semantics, same default (0/unbounded) as before. No behavior change for existing configs. Combine an idle timeout with its hard counterpart for a ceiling on top — the idle-reset deadline is capped so it can't silently push past an explicitly configured `ReadTimeout`/`WriteTimeout`.

Also adds `ReadMinRate`/`WriteMinRate` (bytes/second, 0 = disabled), matching Apache `mod_reqtimeout`'s `MinRate`. Idle-reset alone doesn't bound a client that trickles just enough data to never go idle; with a min rate set, the allowed deadline grows from a fixed start based on bytes transferred so far instead of resetting to a flat window on every call, so a transfer that doesn't sustain the configured rate falls behind real time and gets cut, even though no single read/write ever stalls. In the Caddyfile, min rate is a second, optional argument on the idle-timeout directive rather than a separate one: `read_body_idle 60s 100`/`write_idle 60s 100`.

All new fields default to 1 minute (idle) / 0 (min rate, opt-in) — safe to default the idle timeouts since they're new fields, so no existing config could have depended on a different value.

### Write chunking

`SetWriteDeadline` bounds the whole call it precedes, not just a stall within it: `net.Conn.Write` loops internally until a buffer is fully sent, and `ResponseWriter.ReadFrom` hands the entire remaining source to the connection in one call (sendfile or an internal buffered copy loop — the latter always for TLS, since `*tls.Conn` isn't an `io.ReaderFrom`). Without chunking, a single large `Write`, or any response body copied via `io.Copy` triggering the `ReadFrom` fast path (`http.ServeContent`, static file serving), had its whole transfer bounded by one deadline — silently truncating a slow-but-healthy transfer exactly like a hard `WriteTimeout` would. This is the same bug independently found and fixed the same way in FrankenPHP's `go_ub_write` ([php/frankenphp#2574](https://github.com/php/frankenphp/pull/2574)), and nginx hit it historically too (`sendfile_max_chunk`, added after a single fast connection could seize a worker process entirely).

Fixed by capping each underlying `Write`/`ReadFrom` call and resetting the deadline between chunks. The cap is configurable (`MaxWriteChunk`/`max_write_chunk` on `Server`, `write_max_chunk` in the Caddyfile `timeouts` block), defaulting to 64 KiB — matching nginx's own tunable `sendfile_max_chunk`. `net/sendfile.go` special-cases `*io.LimitedReader`, so chunked `ReadFrom` still gets the sendfile fast path per chunk.

### Per-route granularity

New `timeouts` handler (`http.handlers.timeouts`, Caddyfile directive `timeouts`) applies the same idle-reset `ReadTimeout`/`WriteTimeout`/`ReadMinRate`/`WriteMinRate`/`MaxWriteChunk` per-route, independent of the rest of the server block — matching nginx's `location{}` and Apache's `<Directory>` scoping. Same Caddyfile shape as the server-wide option: `read_timeout 60s 100`/`write_timeout 60s 100` take the min rate as an optional second argument.

Kept separate from `request_body` rather than bolted onto it: `request_body` is about the request body specifically (`max_size`, `set`), while write-side pacing is a response concern that has nothing to do with the request body. A dedicated handler keeps that boundary clean and mirrors the server-wide `timeouts` option one level down.

Covers HTTP/1.1, HTTP/2, and HTTP/3 (quic-go's `http3.responseWriter` implements `SetReadDeadline`/`SetWriteDeadline` directly, on the same stream used for the request body).

## Assistance Disclosure

This PR has been designed and reviewed by me, the code has been written by Claude Code.


## Files (code)

- caddyconfig/httpcaddyfile/directives.go
- caddyconfig/httpcaddyfile/serveroptions.go
- modules/caddyhttp/app.go
- modules/caddyhttp/idletimeout.go
- modules/caddyhttp/requestbody/caddyfile.go
- modules/caddyhttp/requestbody/requestbody.go
- modules/caddyhttp/server.go
- modules/caddyhttp/standard/imports.go
- modules/caddyhttp/timeouts/caddyfile.go
- modules/caddyhttp/timeouts/timeouts.go

## Hidden tests

- modules/caddyhttp/idletimeout_test.go
- modules/caddyhttp/timeouts/timeouts_test.go

## Test functions

- TestIdleTimeoutReader
- TestIdleTimeoutReader_HardDeadlineCapsIdleReset
- TestIdleTimeoutReader_MinRateAllowsSustainedRate
- TestIdleTimeoutReader_MinRateCatchesTrickle
- TestIdleTimeoutWriter
- TestIdleTimeoutWriter_HardDeadlineCapsIdleReset
- TestIdleTimeoutWriter_MaxChunkOverride
- TestIdleTimeoutWriter_ReadFromChunksLargeTransfer
- TestIdleTimeoutWriter_WriteChunksLargePayload
- TestTimeouts_ReadTimeoutIsIdleReset
- TestTimeouts_WriteMaxChunkOverride
