# Changelog

## [Unreleased]

### Added
- Initial release of `dedupe_requests`.
- Server-side fingerprint de-duplication of POST/PUT/PATCH requests (no client idempotency key required).
- Controller macro `dedupe_requests` with `on:` (add) and `skip:` (remove) over an inherited per-action map, plus `skip_dedupe_requests`; per-action TTL by repeating the line.
- Global configuration via `DedupeRequests.configure` (redis, mode, ttl, digest, namespace, caller_id, fingerprint override, conflict status/body, logger, metrics hooks).
- Three operating modes: `:off`, `:observe` (shadow), `:enforce`.
- Atomic `SET NX EX` claim with a random token and token-safe Lua check-and-del release.
- Keeps the fingerprint on a 2xx or 3xx (incl. Post/Redirect/Get) response; releases it on a 4xx/5xx response or a raised exception (around pattern), so failed requests can be retried.
- Fail-open behavior when Redis is unreachable.
- `duplicate_detected` / `duplicate_rejected` observability hooks.
