## Context
Caddy's logging module can filter logged fields; the built-in `cookie` filter hashes,
replaces or deletes named cookies inside a logged `Cookie` request header. There is no
equivalent for the `Set-Cookie` response header, whose values have a different shape:
one cookie plus its attributes per header value (`name=value; Path=/; Secure`).

## Requirement
- Add a `set_cookie` log field filter, registered as a Caddy module beside the existing
  cookie filter, with the same three actions and the same Caddyfile shape as `cookie`:
  `hash`, `replace <value>`, `delete`, each keyed by an exact, case-sensitive cookie name.
- The field being filtered is an array of `Set-Cookie` header values. Each value is
  handled on its own: only the leading `name=value` pair is transformed; the attribute
  suffix after it (`; Path=/; HttpOnly`, ...) is preserved verbatim and never
  re-serialised or normalised.
- `hash` replaces the cookie value with the same short hash the cookie filter uses;
  `replace` substitutes the given value, keeping the original quoting of the value if it
  was quoted; `delete` removes that whole header value from the array. Cookies whose name
  matches no action pass through unchanged.
- A header value that cannot be parsed as a `Set-Cookie` line passes through unchanged.
- Cookie names are matched exactly; `Session` does not match an action for `session`.
- The filter must work for the standard access-log field that carries response headers,
  and it must be usable from the Caddyfile `format filter { fields { ... } }` block.

## Constraints
- Go; no new module dependencies; follow the structure and conventions of the existing
  cookie filter and its Caddyfile unmarshalling.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
The test file at `modules/logging/filters_test.go` was updated in this checkout and
currently fails to compile. Make it pass without modifying it. `go test ./...` must
stay green.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
