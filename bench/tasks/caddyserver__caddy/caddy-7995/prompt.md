## Context
Caddy adapts Caddyfiles to JSON through the HTTP server type in the `httpcaddyfile`
package. The `order` global option lets one Caddyfile move a directive relative to
the others (`order respond first`, `order redir before respond`, ...). Plugins can also
register a position for their own directive at init time.

## Requirement
- The `order` global option must affect only the adaptation that contains it. A
  Caddyfile adapted afterwards, in the same process, must produce exactly the JSON it
  would have produced before, in the default directive order.
- An adaptation whose `order` option is invalid (for example it names an unknown
  directive) must fail with an error and must leave nothing behind: the next
  adaptation must again produce the default result.
- Several adaptations that use `order` may run concurrently, with or without a shared
  options map, without corrupting the directive order or each other's output. The
  hidden tests run this case under the race detector's assumptions: no shared
  mutable order state between adaptations.
- Reusing the same options map for a second adaptation must be safe; the first
  adaptation must not leave state in it that changes the second.
- A directive order registered by a plugin at init time (before/after an existing
  directive) must keep working and be visible to every adaptation.
- No exported API changes, no locks; the default order itself is never mutated by an
  adaptation.

## Constraints
- Go; no new module dependencies; keep the existing behaviour for every Caddyfile
  that already adapted correctly; follow the conventions of the surrounding code.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
The test file at `caddyconfig/httpcaddyfile/directives_test.go` was updated in this
checkout and currently fails. Make it pass without modifying it. `go test ./...` must
stay green.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
