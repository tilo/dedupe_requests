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
4. After the action: a **2xx, or a 3xx redirect** (the Post/Redirect/Get pattern is a successful create), keeps the fingerprint until the TTL expires — so a later duplicate is blocked; a **4xx/5xx or a raised exception releases** the fingerprint, so a genuine retry of a failed request is allowed.

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
  c.caller_id = ->(controller) { controller.current_user&.id }   # per-caller scoping
  c.logger    = Rails.logger        # where Redis/fail-open errors are logged
end
```

The guarded verbs are fixed — **POST, PUT, PATCH**. They're not a config knob, and GET/DELETE are never deduped.

### 2. Per-controller — the `dedupe_requests` macro

Include the concern once (usually in `ApplicationController`), then declare which actions are guarded:

```ruby
class ApplicationController < ActionController::Base
  include DedupeRequests::Controller
  dedupe_requests on: %i[create update]     # project-wide baseline
end
```

Each `dedupe_requests` line **adds** the actions it names to the list of deduplicated actions — it does not replace anything (same as Rails' own `before_action only:`). A controller inherits its parent's guarded actions and can add more or drop some:

The list of deduplicated actions is matched by **action name**: once the baseline names `create`, every controller that inherits it deduplicates its own `create` action — not just `ApplicationController`'s. Opt a controller out with `skip:`.

| Option  | Effect on this controller                      |
| ------- | ---------------------------------------------- |
| `on:`   | guard these actions (uses this line's `ttl:`)  |
| `skip:` | stop guarding these actions — no dedupe at all  |

```ruby
class OrdersController < ApplicationController
  dedupe_requests on: %i[approve cancel]   # adds approve/cancel to the inherited create/update
end

class DraftsController < ApplicationController
  dedupe_requests skip: %i[create]           # guards everything inherited except create
end
```

#### Per-action TTL

A `ttl:` applies to exactly the actions named on its line. Give different actions different windows by repeating the line — a list shares one TTL:

```ruby
class PaymentsController < ApplicationController
  dedupe_requests on: %i[create charge], ttl: 120   # create + charge → 120s
  dedupe_requests on: [:refund],         ttl: 600   # refund → 600s
end
```

An action with no `ttl:` falls back to the global `config.ttl`; re-declaring an action updates its TTL.

You never specify HTTP verbs per action — the route already determines the verb, and the gem only ever guards POST/PUT/PATCH.

### 3. Per-caller identity (`caller_id`)

Dedup is scoped per caller, so two different users sending the same payload don't collide. `caller_id` is a callable given the **controller**, so it can read whatever identifies the caller:

```ruby
DedupeRequests.configure do |c|
  c.caller_id = ->(controller) { controller.current_user&.id }                       # current_user
  # c.caller_id = ->(controller) { controller.request.get_header("HTTP_X_API_KEY") }  # a header
  # c.caller_id = ->(controller) { controller.some_method }                           # any controller method
end
```

If you don't set it, the default derives identity from the `Authorization` header, falling back to a Rails session cookie — so token- and cookie-auth apps work with no configuration.

> **Note:** make sure you configure `caller_id` correctly for your API. If it can't derive an identity (no `Authorization` header and no session cookie), it falls back to `nil` — and then *different* callers sending the same payload to the same endpoint are treated as one request, so the second gets a 409. That's probably not what you want, so set `caller_id` to whatever identifies a caller in your app.

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
  c.on_duplicate_detected = ->(info) { StatsD.increment("dedupe.detected", tags: { controller: info[:controller], action: info[:action], verb: info[:verb] }) }
  c.on_duplicate_rejected = ->(info) { StatsD.increment("dedupe.rejected", tags: { controller: info[:controller], action: info[:action], verb: info[:verb] }) }
end
```

Each hook receives `{ fingerprint:, controller:, action:, verb:, path: }`. `duplicate_detected` fires in both `observe` and `enforce`; `duplicate_rejected` only when a 409 is actually returned.

When tagging metrics, use only `controller`, `action`, and `verb` — these come from a small fixed set. Do **not** tag with `fingerprint` or `path`: the fingerprint is unique per request and the path usually contains record ids, so tagging with them creates a separate counter per request (a surprise bill on Datadog, or dropped series and broken dashboards). Log those instead if you need them.

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
- **Compile Ruby with OpenSSL — for speed.** The fingerprint hashes the request body on the hot path. It uses `OpenSSL::Digest`, which runs on the CPU's SHA instructions (SHA-NI / ARM crypto) at ~1.5–2 GB/s. If your Ruby is built **without** OpenSSL, the gem still works — it falls back to the stdlib `Digest` — but that's a portable software implementation (~300–500 MB/s, no SHA instructions), several times slower on large bodies. So build Ruby with OpenSSL in production.

## Configuration reference

| Option                   | Default              | Purpose                                                            |
| ------------------------ | -------------------- | ----------------------------------------------------------------- |
| `redis`                  | `nil`                | A Redis client or a connection pool.                              |
| `store`                  | built from `redis`   | Inject a custom store responding to `claim` / `release`.          |
| `mode`                   | `:enforce`           | `:off` / `:observe` / `:enforce`.                                 |
| `ttl`                    | `90`                 | Dedup window, in seconds.                                         |
| `digest`                 | `:sha256`            | `:sha256` / `:sha512` / `:sha1` / `:md5`, or a callable.          |
| `namespace`              | `"dedupe_requests"`  | Redis key prefix (`<namespace>:dedup:<hash>`).                    |
| `caller_id`              | Authorization / session cookie | Callable **given the controller**, returns a per-caller identity (e.g. `->(c){ c.current_user&.id }`, a header via `c.request`, or any controller method). Default derives it from the Authorization header / session cookie. |
| `fingerprint`            | `nil`                | Callable **given the request**, returns the fingerprint string — fully overriding the default computation. |
| `conflict_status`        | `409`                | Status returned for a rejected duplicate.                        |
| `conflict_body`          | structured errors    | JSON body for a rejected duplicate.                              |
| `logger`                 | `nil`                | Where Redis errors are logged.                                   |
| `on_duplicate_detected`  | `nil`                | Hook fired when a duplicate is seen.                             |
| `on_duplicate_rejected`  | `nil`                | Hook fired when a duplicate is rejected with a 409.             |

> **Why `caller_id` is given the controller but `fingerprint` is given the request:** they answer different questions at different layers. `caller_id` identifies *who* is calling — an app-level question that often needs controller context like `current_user`, so it receives the controller. `fingerprint` characterizes *which request* this is — a pure function of the HTTP request (verb + path + query + body), computed in the framework-agnostic core where the body is hashed on the hot path, so it receives the request directly. Each callable is handed the object that matches its job.

## Limitations

Auto-hashing the payload means two *genuinely separate* requests with identical content (e.g. deliberately creating two identical records in quick succession) look like a duplicate, and the second gets a 409. Mitigations: keep the TTL short, and opt specific actions out with `skip_dedupe_requests` (or `skip:`). This is best-effort de-duplication, not exactly-once semantics. It does **not** use client-supplied idempotency keys at all — an `Idempotency-Key` (or any similar) header is ignored and has no effect on the fingerprint; de-duplication is entirely server-computed.

## Development

```sh
bundle install
bundle exec rspec
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).
