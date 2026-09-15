# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #7877 rewrite: fix strip_path_suffix ignoring percent-encoding (merged 2026-08-28T09:44:05Z)

### What

`StripPathSuffix` (`uri strip_suffix` / `handle_path` in the Caddyfile) is documented to behave like `StripPathPrefix`: the suffix is matched in normalized (unescaped) space, except where the pattern itself uses a `%xx` escape. That normalized comparison never actually happened for suffixes.

Suffix stripping was implemented as `reverse(trimPathPrefix(reverse(path), reverse(suffix)))`. Reversing the strings moves the `%` to the *end* of each `%xx` escape, which defeats `trimPathPrefix`'s escape detection (it expects `%` to precede the two hex digits). So a decoded pattern silently failed to match a percent-encoded path.

### Demonstration

| operation | path | expected | before | after |
|---|---|---|---|---|
| `strip_prefix /a/b/c` | `/a%2Fb/c/d` | `/d` | `/d` ✓ | `/d` ✓ |
| `strip_suffix /b/c` | `/a/b%2Fc` | `/a` | `/a/b%2Fc` ✗ | `/a` ✓ |
| `strip_suffix bc` | `/a%62c` | `/a` | `/a%62c` ✗ | `/a` ✓ |

Prefix and suffix share identical doc comments but produced different results.

### Fix

Replace the reverse trick with a dedicated `trimPathSuffix` that iterates from the ends of both strings and applies the same escape-aware, case-insensitive comparison as `trimPathPrefix`. An escape in the pattern is still compared literally, so `%2fsuffix` continues to require the path to contain that exact escape (covered by an added negative test).

Present since #4948, which introduced both the escape-aware `trimPathPrefix` and the reverse-based suffix trimming.

### Testing

Added three cases to `TestRewrite` (two fail before the fix, the negative guard passes both ways); `go test ./modules/caddyhttp/...` passes, gofmt/vet clean.

---
*Disclosure: this bug was found by a code audit of the rewrite handlers, and the fix and tests were prepared with the assistance of an LLM (Claude). The diagnosis was verified by a human via fail-before/pass-after runs.*


## Files (code)

- modules/caddyhttp/rewrite/rewrite.go

## Hidden tests

- modules/caddyhttp/rewrite/rewrite_test.go

## Test functions

- TestQueryOpsRenameNoOpCases
- TestQueryOpsReplaceScopedToKey
- TestRewrite
