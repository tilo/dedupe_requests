# Changelog

## 1.0.0.pre2 (2026-06-17)

### Changed
- **`caller_id` is now required and has no default.** The old default keyed on the `Authorization` header / session cookie — but **rotating tokens are unsafe to key on**, so that default was removed. Configure `caller_id` with a callable that returns a stable, non-secret identifier (a user id, a JWT `sub`, an API-client id).
- When `caller_id` is unset or resolves to `nil`, de-duplication is now **skipped** for that request (it's allowed through) and a warning is logged — instead of treating all unidentified callers as one identity (which could wrongly 409 a different caller's identical request). Return a fixed string from `caller_id` to dedupe globally.

## 1.0.0.pre1 (2026-06-16)

Initial release. See the [README](README.md) for full usage and configuration.

### Summary
- Server-side de-duplication of inbound mutating requests — **POST/PUT/PATCH only** (GET/DELETE are never deduped). No client-supplied idempotency key required: the server computes a fingerprint of each request (caller + verb + path + query + body).
- Controller macro `dedupe_requests` with `on:` (add) and `skip:` (remove), plus `skip_dedupe_requests`, over an inherited per-action map — declare a baseline in `ApplicationController` and refine it per subclass. Guarded actions are matched by action name.
- Per-action TTL by repeating the macro line; actions without one fall back to the global `ttl`.
- Per-caller scoping via `caller_id` — by default derived from the `Authorization` header (or a Rails session cookie), and fully overridable with your own callable.
- Pluggable `fingerprint` override to replace the default fingerprint computation entirely.
- Three operating modes for safe rollout: `:off`, `:observe` (detect-only / shadow), and `:enforce` (reject duplicates).
- Configurable 409 conflict response (`conflict_status`, `conflict_body`), with an `X-Dedupe-Request` header set on rejections.
- Reliability: atomic `SET NX EX` claim with a random token and a token-safe Lua check-and-del release; **fails open** (allows the request through) when Redis is unreachable.
- Retry-friendly claim lifecycle: keeps the fingerprint on a 2xx or 3xx response (including Post/Redirect/Get), and releases it on a 4xx/5xx response or a raised exception, so a genuinely failed request can be retried.
- Observability hooks: `on_duplicate_detected` and `on_duplicate_rejected`.
- Configurable digest (`:sha256` default, plus `:sha1` / `:sha512` / `:md5`, or a callable), key `namespace`, and `logger`.
