# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #7888 logging: add set_cookie log filter for Set-Cookie response headers (merged 2026-08-13T04:59:32Z)

Closes #7887

This adds a new `set_cookie` log field filter for logged `Set-Cookie` response header values.

It supports the same actions as the existing `cookie` filter:

- `hash`
- `replace`
- `delete`

The main intended use is for access log fields such as `resp_headers>Set-Cookie` when `log_credentials` is enabled.

## Motivation

Caddy already has a built-in `cookie` log filter for logged `Cookie` request header values.

That logic does not map directly to `Set-Cookie`, because `Set-Cookie` is structured as one cookie plus attributes per header value. Reusing request-cookie-style handling can produce partially useful output, but does not preserve `Set-Cookie` attributes correctly.

## Implementation notes

This implementation uses a hybrid approach:

- it uses `http.ParseSetCookie()` to identify the cookie name and value
- it does not re-serialize the full header with `Cookie.String()`
- it preserves the original attribute suffix verbatim
- it only transforms the leading cookie value
- invalid / unparseable `Set-Cookie` lines are passed through unchanged

This avoids normalization and preserves unrecognized attributes.

## Example

```caddyfile
log {
	format filter {
		fields {
			resp_headers>Set-Cookie set_cookie {
				hash session
				delete csrf
			}
		}
	}
}
```

## Tests

Added tests for:

- `hash`
- `replace`
- `delete`
- first-match-wins behavior
- invalid header passthrough
- case-sensitive cookie-name matching
- Set-Cookie values without attributes
- empty cookie value hashing
- preserving quoted values / suffix formatting / unknown attributes

## Assistance Disclosure

ChatGPT/Codex was used to help draft the issue/PR text, refine the implementation approach, and assist with code and test changes. The overall feature idea and final decisions on the technical approach and submitted content were mine.


## Files (code)

- modules/logging/filters.go

## Hidden tests

- modules/logging/filters_test.go

## Test functions

- TestCookieFilter
- TestHashFilterMultiValue
- TestHashFilterSingleValue
- TestIPMaskCommaValue
- TestIPMaskMultiValue
- TestIPMaskSingleValue
- TestMultiRegexpFilterAddOperation
- TestMultiRegexpFilterInputSizeLimit
- TestMultiRegexpFilterMultiValue
- TestMultiRegexpFilterMultipleOperations
- TestMultiRegexpFilterOverlappingPatterns
- TestMultiRegexpFilterSecurityLimits
- TestMultiRegexpFilterSingleOperation
- TestMultiRegexpFilterValidation
- TestQueryFilterMultiValue
- TestQueryFilterSingleValue
- TestRegexpFilterMultiValue
- TestRegexpFilterSingleValue
- TestSetCookieFilter
- TestSetCookieFilterCookieNameMatchingIsCaseSensitive
- TestSetCookieFilterFirstMatchWins
- TestSetCookieFilterHashEmptyValue
- TestSetCookieFilterHashWithoutAttributes
- TestSetCookieFilterInvalidHeaderPassesThrough
- TestValidateCookieFilter
- TestValidateQueryFilter
- TestValidateSetCookieFilter
