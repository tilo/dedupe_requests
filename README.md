# dedupe_requests

Automatic server-side de-duplication of inbound mutating Rails requests (POST / PUT / PATCH), with **no client-side idempotency key required**.

When a client re-sends the same mutating request — because of a retry, a network timeout, a double-click, or a buggy client — a non-idempotent endpoint often turns the duplicate into a 5xx (the resource is already created or modified).

One go-to solution for this used to be to require the client to provide a idempotency key together with the request, and then reject duplicate requests (requests that use a previous idemptotency key).

`dedupe_requests` simplifies this, removing the requirement for providing an idempotency key, and instead auto-computes a fingerprint of each mutating request (effectively auto-generating the idempotency key on-the-fly), claims it atomically in Redis, and short-circuits a duplicate seen within a configurable window with a clean **409 Conflict** instead of letting it blow up your app.

This is different from the usual idempotency-key gems: the **server** computes the fingerprint from the request itself, so
* existing clients need no changes
* clients no longer need to send an idempotency_key

## How it works

1. A mutating request (POST/PUT/PATCH) arrives for a guarded action.
2. The server computes a fingerprint: `digest(caller_id + verb + path + query + body)`.
3. It runs an atomic `SET key <token> NX EX <ttl>` in Redis.
   - **Key already existed** → it's a duplicate. In `enforce` mode, respond `409`; in `observe` mode, just record it and let it through.
   - **Key created** → first occurrence. Run the action normally.
4. After the action: a `2xx` keeps the fingerprint until the TTL expires (so a later duplicate is blocked); **any non-2xx or a raised exception releases the fingerprint**, so a genuine retry of a failed request is allowed.

GET and DELETE are never deduped. Time is not part of the fingerprint — the window is the Redis TTL.

## Installation

```ruby
# Gemfile
gem "dedupe_requests"
```

## Usage

### 1. Global defaults — an initializer

```ruby
# config/initializers/dedupe_requests.rb
DedupeRequests.configure do |c|
  c.redis     = Redis.new(url: ENV["REDIS_URL"])
  c.mode      = :enforce            # :off | :observe | :enforce
  c.ttl       = 90                  # the dedup window, in seconds
  c.digest    = :sha256             # :sha256 | :sha512 | :sha1 | :md5 | ->(bytes) { ... }
  c.namespace = "myapp"             # Redis key prefix
  c.caller_id = ->(req) { req.get_header("HTTP_AUTHORIZATION") } # per-caller scoping
  c.logger    = Rails.logger        # where Redis/fail-open errors are logged
end
```

The guarded verbs are fixed — **POST, PUT, PATCH**. They're not a config knob, and GET/DELETE are never deduped.

### 2. Per-controller — the `dedupe_requests` macro

Include the concern once (usually in `ApplicationController`), then declare which actions are guarded:

```ruby
class ApplicationController < ActionController::Base
  include DedupeRequests::Controller
  dedupe_requests only: %i[create update]     # project-wide baseline
end
```

Subclasses adjust the inherited baseline with three set operations:

| Option  | Meaning for this controller        | Result vs. inherited set |
| ------- | ---------------------------------- | ------------------------ |
| `only:` | exact list — ignore the baseline   | replace                  |
| `also:` | baseline **plus** these            | inherited ∪ these        |
| `skip:` | baseline **minus** these           | inherited − these        |

```ruby
class ReportsController < ApplicationController
  dedupe_requests only: %i[generate]          # ignore baseline; just this action
end

class DraftsController < ApplicationController
  dedupe_requests skip: %i[create]            # baseline minus create
end

class OrdersController < ApplicationController
  dedupe_requests also: %i[approve cancel]    # baseline plus these two
end
```

A per-controller TTL override rides on the same line: `dedupe_requests only: %i[create], ttl: 120`.

You never specify HTTP verbs per action — the route already determines the verb, and the gem only ever guards POST/PUT/PATCH.

## Modes and safe rollout

`mode` has three states:

- `:off` — disabled; no fingerprinting, no storage.
- `:observe` — **shadow mode**: compute and store fingerprints and fire the metrics hooks, but never return a 409. Duplicates are detected and reported only.
- `:enforce` — detect, store, and reject duplicates with a 409.

Recommended rollout on a live service: enable `:observe`, build a dashboard from the `duplicate_detected` hook, watch real volume for a week or two, then flip to `:enforce`.

## Observability

Wire the hooks to your metrics/logging backend (Datadog, StatsD, logs — your choice):

```ruby
DedupeRequests.configure do |c|
  c.on_duplicate_detected = ->(info) { StatsD.increment("dedupe.detected", tags: info) }
  c.on_duplicate_rejected = ->(info) { StatsD.increment("dedupe.rejected", tags: info) }
end
```

Each hook receives `{ fingerprint:, controller:, action:, verb:, path: }`. `duplicate_detected` fires in both `observe` and `enforce`; `duplicate_rejected` only when a 409 is actually returned.

## The 409 response

Default body (override via `config.conflict_body`, and status via `config.conflict_status`):

```json
{
  "errors": [{
    "error_key": "base",
    "category": "duplicate_operation",
    "message": "Duplicate request detected. A matching request is in-flight or recently completed."
  }]
}
```

A `409` is deliberate: well-behaved retrying clients do **not** loop on a 409 (they do on 5xx), so a duplicate is rejected cleanly without triggering further retries.

## Reliability

- **Fail open.** If Redis is unreachable, the request proceeds normally — a Redis outage never blocks traffic. Redis errors are rescued and logged (set `config.logger`). The logger is used **only** for these Redis/fail-open errors — not for normal duplicate handling (use the hooks above for that) — and it is wired automatically only when the store is built from `config.redis`. If you inject your own `config.store`, pass it a logger directly.
- **Token-safe release.** Each claim stores a random token; release deletes the key only if it still holds that token (via a Lua check-and-del), so a slow request whose TTL expired can't wipe a newer request's fresh claim.

## Configuration reference

| Option                   | Default              | Purpose                                                            |
| ------------------------ | -------------------- | ----------------------------------------------------------------- |
| `redis`                  | `nil`                | A Redis client or a connection pool.                              |
| `store`                  | built from `redis`   | Inject a custom store responding to `claim` / `release`.          |
| `mode`                   | `:enforce`           | `:off` / `:observe` / `:enforce`.                                 |
| `ttl`                    | `90`                 | Dedup window, in seconds.                                         |
| `digest`                 | `:sha256`            | `:sha256` / `:sha512` / `:sha1` / `:md5`, or a callable.          |
| `namespace`              | `"dedupe_requests"`  | Redis key prefix (`<namespace>:dedup:<hash>`).                    |
| `caller_id`              | Authorization / session cookie | Callable returning a per-caller identity.             |
| `fingerprint`            | `nil`                | Callable to fully override fingerprint computation.              |
| `max_body_bytes`         | `nil`                | Cap how many body bytes are hashed (for very large payloads).     |
| `conflict_status`        | `409`                | Status returned for a rejected duplicate.                        |
| `conflict_body`          | structured errors    | JSON body for a rejected duplicate.                              |
| `logger`                 | `nil`                | Where Redis errors are logged.                                   |
| `on_duplicate_detected`  | `nil`                | Hook fired when a duplicate is seen.                             |
| `on_duplicate_rejected`  | `nil`                | Hook fired when a duplicate is rejected with a 409.             |

## Limitations

Auto-hashing the payload means two *genuinely separate* requests with identical content (e.g. deliberately creating two identical records in quick succession) look like a duplicate, and the second gets a 409. Mitigations: keep the TTL short, and opt specific actions out with `skip_dedupe_requests` (or `skip:`). This is best-effort de-duplication, not exactly-once semantics, and it never replaces an explicit idempotency key if a caller already sends one.

## Development

```sh
bundle install
bundle exec rspec
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).
