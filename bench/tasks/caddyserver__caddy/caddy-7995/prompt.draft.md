# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #7995 httpcaddyfile: give each adaptation its own directive order (merged 2026-09-06T13:20:45Z)

Fixes #7994.

`parseOptOrder` was modifying the global `directiveOrder` on every adapt. Since it could share the same underlying slice as `defaultDirectiveOrder`, concurrent adapts could permanently remove entries from the default order. After that, any adapt would fail until restart, even ones not using `order`.

### What changed

* `directiveOrder` is now only changed by `RegisterDirectiveOrder` during init.
* `parseOptOrder` works with a local copy and returns the order instead of changing a global.
* `sortRoutes` and `buildSubroute` now receive the order directly.
* `Setup` clones the options map and drops `order` from tis untouched and reusing the same map is safe.
* `RegisterDirectiveOrder` now inserts into a cloned slice.

No mutexes or exported API changes.

### Tests

Added tests for sequential/concurrent adapts, reused options maps, recovery after a bad `order`, the original race reproducer, and plugin-registered directive order. All of them fail on master.

### Disclosure

I used LLM to generate the tests.

## Files (code)

- caddyconfig/httpcaddyfile/builtins.go
- caddyconfig/httpcaddyfile/directives.go
- caddyconfig/httpcaddyfile/httptype.go
- caddyconfig/httpcaddyfile/options.go

## Hidden tests

- caddyconfig/httpcaddyfile/directives_test.go

## Test functions

- TestAdaptDirectiveOrderAfterError
- TestAdaptDirectiveOrderIsolation
- TestAdaptDirectiveOrderWithReusedOptions
- TestConcurrentAdaptDirectiveOrder
- TestConcurrentAdaptDirectiveOrderWithReusedOptions
- TestHostsFromKeys
- TestRegisterDirectiveOrderWithOrderOption
