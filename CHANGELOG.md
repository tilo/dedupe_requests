# Changelog

## [Unreleased]

### Added
- Initial release of `dedupe_requests`.
- Server-side fingerprint de-duplication of POST/PUT/PATCH requests (no client idempotency key required).
- Controller macro `dedupe_requests` with `only:` / `also:` / `skip:` set operations over an inherited action set, plus `skip_dedupe_requests`.
- Global configuration via `DedupeRequests.configure` (redis, mode, ttl, digest, namespace, caller_id, fingerprint override, max_body_bytes, conflict status/body, logger, metrics hooks).
- Three operating modes: `:off`, `:observe` (shadow), `:enforce`.
- Atomic `SET NX EX` claim with a random token and token-safe Lua check-and-del release.
- Releases the fingerprint on any non-2xx response or raised exception (around pattern), so failed requests can be retried.
- Fail-open behavior when Redis is unreachable.
- `duplicate_detected` / `duplicate_rejected` observability hooks.
