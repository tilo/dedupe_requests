# frozen_string_literal: true

#
# End-to-end test of dedupe_requests against a REAL HTTP server.
#
# Boots examples/config.ru under Puma on a real socket and fires real HTTP at it
# with Net::HTTP. The test speaks ONLY HTTP — it never touches Redis. The gem
# writes the claims, Redis expires them on its own TTL; we just send requests in
# a realistic order, with realistic JSON payloads, from a few simulated callers,
# and assert on the status codes that come back.
#
# Covers, on one enforce-mode server:
#
#   (1) baseline at the application-controller level   (WidgetsController declares nothing)
#   (2) skipping a baseline action in a subclass        (DraftsController  skip: [:create])
#   (3) adding an action in a subclass                  (OrdersController  on: [:approve])
#   (4) changing the TTL in a subclass                  (PaymentsController on: [:create], ttl)
#   (5) per-caller scoping                              (same payload, different caller -> not a dup)
#   (6) different payload, same caller                  (-> not a dup)
#   (7) concurrent in-flight duplicate                  (two at once -> exactly one wins)
#   (8) release on failure                              (4xx response and a raised 500 -> retry allowed)
#   (9) GET / DELETE are never deduplicated             (even when the action is guarded by name)
#  (10) 3xx redirect keeps the claim                    (Post/Redirect/Get -> duplicate still blocked)
#  (12) duplicate-notification hooks fire               (on_duplicate_detected AND on_duplicate_rejected)
#
# On a second server booted in observe mode:
#
#  (11) observe mode lets duplicates through            (detected fires, rejected does NOT)
#
# On a third server booted with a custom fingerprint:
#
#  (13) the fingerprint override callable is used       (custom fingerprint replaces the default)
#
# On a fourth server booted with a custom caller_id:
#
#  (14) the caller_id override callable is used          (identity from X-Api-Key, not Authorization)
#
# Callers are simulated with an `Authorization: Bearer <token>` header, which is
# what the gem's default caller_id reads. Two requests are a duplicate only when
# caller + path + payload all match.
#
# Usage (needs a running Redis — the gem talks to it, not this test):
#
#   redis-server &
#   bundle exec ruby examples/end_to_end_test.rb      # or: bundle exec rake integration
#
# Exits 0 if every check passes, 1 otherwise.

require "net/http"
require "json"
require "securerandom"
require "tmpdir"

ENFORCE_PORT     = Integer(ENV.fetch("PORT", "9377"))
OBSERVE_PORT     = ENFORCE_PORT + 1
FINGERPRINT_PORT = ENFORCE_PORT + 2
CALLER_ID_PORT   = ENFORCE_PORT + 3
HOST             = "127.0.0.1"
ROOT         = File.expand_path("..", __dir__)
CONFIG_RU    = File.join(__dir__, "config.ru")
REDIS_URL    = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")
RUN          = SecureRandom.uuid # unique per run, so a rerun's payloads don't collide with still-live claims

GLOBAL_TTL    = 2
PAYMENT_TTL   = 5
SLOW_SECONDS  = 1

# which booted server the request helpers talk to (switched per server in with_server)
$port = ENFORCE_PORT # rubocop:disable Style/GlobalVars

# Simulated callers -> the Authorization header the gem's default caller_id reads.
CALLERS = {
  alice: "Bearer token-alice",
  bob: "Bearer token-bob",
  carol: "Bearer token-carol"
}.freeze

# Realistic per-endpoint payloads. Each distinct logical request gets its own
# body so that, within a run, only an intentional repeat (same caller + path +
# payload) looks like a duplicate.
WIDGET_CREATE    = { name: "Blue Widget", color: "blue", quantity: 3 }.freeze
WIDGET_UPDATE    = { color: "green", quantity: 5 }.freeze
WIDGET_RED       = { name: "Red Widget", color: "red", quantity: 1 }.freeze
WIDGET_GREEN     = { name: "Green Widget", color: "green", quantity: 7 }.freeze
DRAFT_CREATE     = { title: "Q3 Plan", body: "First outline of the Q3 roadmap" }.freeze
DRAFT_UPDATE     = { body: "Revised outline with a budget section" }.freeze
ORDER_APPROVE    = { approved_by: "manager-7", note: "cleared for fulfillment" }.freeze
ORDER_CREATE     = { customer_id: 42, items: [{ sku: "ABC-123", qty: 2 }], total_cents: 4990 }.freeze
ORDER_CREATE_TTL = { customer_id: 77, items: [{ sku: "XYZ-9", qty: 1 }], total_cents: 1500 }.freeze
PAYMENT_CREATE   = { order_id: 1001, amount_cents: 1500, currency: "USD" }.freeze
PAYMENT_MULTI    = { order_id: 2002, amount_cents: 9900, currency: "EUR" }.freeze
SLOW_JOB         = { job: "reindex", shard: 4 }.freeze
FAIL_PAYLOAD     = { trigger: "boom" }.freeze
READ_PAYLOAD     = { page: 1 }.freeze
REDIRECT_PAYLOAD = { ticket: "T-555" }.freeze
OBSERVE_PAYLOAD  = { note: "observe-mode duplicate" }.freeze
HOOK_PAYLOAD     = { event: "hook-check" }.freeze

# ---------------------------------------------------------------------------
# tiny assertion harness
# ---------------------------------------------------------------------------
FAILURES = [] # rubocop:disable Style/MutableConstant -- appended to at runtime, must stay mutable
def check(label, got, expected)
  ok = got == expected
  puts format("  %-64s %-26s %s", label, "got #{got.inspect}", ok ? "OK" : "FAIL (want #{expected.inspect})")
  FAILURES << label unless ok
  ok
end

# ---------------------------------------------------------------------------
# real HTTP, real socket — the only thing this test talks to
# ---------------------------------------------------------------------------
# A request from caller `as`, carrying a realistic JSON `payload`. The ?run=
# query only isolates one test run from the next (it is NOT meant as a payload);
# the gem fingerprints caller + verb + path + query + body.
def request(method, path, as:, payload: nil, api_key: nil)
  klass = { post: Net::HTTP::Post, patch: Net::HTTP::Patch, get: Net::HTTP::Get, delete: Net::HTTP::Delete }.fetch(method)
  req = klass.new("#{path}?run=#{RUN}", "content-type" => "application/json")
  req["Authorization"] = CALLERS.fetch(as)
  req["X-Api-Key"] = api_key if api_key
  req.body = JSON.generate(payload) if payload
  Net::HTTP.start(HOST, $port) { |http| http.request(req) } # rubocop:disable Style/GlobalVars
end

def post(path, payload:, as: :alice, api_key: nil)
  request(:post, path, payload: payload, as: as, api_key: api_key)
end

def patch(path, payload:, as: :alice, api_key: nil)
  request(:patch, path, payload: payload, as: as, api_key: api_key)
end

def status(response)
  response.code.to_i
end

# Read the hook invocations the server recorded, over HTTP (GET is never deduped).
def hook_events
  JSON.parse(request(:get, "/_hooks", as: :alice).body).fetch("events")
end

def wait_for_server(port)
  40.times do
    Net::HTTP.start(HOST, port) { |http| http.get("/") }
    return true
  rescue StandardError
    sleep 0.25
  end
  false
end

# ---------------------------------------------------------------------------
# boot Puma serving config.ru on a real port, run a block against it, tear down
# ---------------------------------------------------------------------------
def with_server(port, extra_env = {})
  env = {
    "REDIS_URL" => REDIS_URL,
    "DEDUPE_TTL" => GLOBAL_TTL.to_s,
    "DEDUPE_PAYMENT_TTL" => PAYMENT_TTL.to_s,
    "DEDUPE_SLOW_SECONDS" => SLOW_SECONDS.to_s
  }.merge(extra_env)
  log = File.join(Dir.tmpdir, "dedupe_puma_#{port}.log")
  pid = spawn(
    env, "bundle", "exec", "puma", CONFIG_RU, "-b", "tcp://#{HOST}:#{port}", "-t", "5:5", "--silent",
    chdir: ROOT, out: log, err: log
  )
  begin
    unless wait_for_server(port)
      warn "server did not come up on #{HOST}:#{port} — puma log:"
      warn File.read(log) if File.exist?(log)
      FAILURES << "server boot on port #{port}"
      return
    end
    $port = port # rubocop:disable Style/GlobalVars
    yield
  ensure
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH
      # server already gone
    end
  end
end

# ===========================================================================
# enforce-mode server: scenarios (1)..(10)
# ===========================================================================
with_server(ENFORCE_PORT) do
  puts "\n(1) BASELINE at the application-controller level (WidgetsController declares nothing)"
  check("POST  /widgets   alice (first)",     status(post("/widgets", payload: WIDGET_CREATE)),      201)
  check("POST  /widgets   alice (duplicate)", status(post("/widgets", payload: WIDGET_CREATE)),      409)
  check("PATCH /widgets/1 alice (first)",     status(patch("/widgets/1", payload: WIDGET_UPDATE)),   201)
  check("PATCH /widgets/1 alice (duplicate)", status(patch("/widgets/1", payload: WIDGET_UPDATE)),   409)

  puts "\n(2) SKIP override in a subclass (DraftsController skip: [:create]; update still guarded)"
  check("POST  /drafts   alice (first)",      status(post("/drafts", payload: DRAFT_CREATE)),        201)
  check("POST  /drafts   alice (same again)", status(post("/drafts", payload: DRAFT_CREATE)),        201) # NOT deduped
  check("PATCH /drafts/1 alice (first)",      status(patch("/drafts/1", payload: DRAFT_UPDATE)),     201)
  check("PATCH /drafts/1 alice (duplicate)",  status(patch("/drafts/1", payload: DRAFT_UPDATE)),     409) # still guarded

  puts "\n(3) ADD an action in a subclass (OrdersController on: [:approve]; baseline still inherited)"
  check("POST /orders/1/approve alice (first)",     status(post("/orders/1/approve", payload: ORDER_APPROVE)), 201)
  check("POST /orders/1/approve alice (duplicate)", status(post("/orders/1/approve", payload: ORDER_APPROVE)), 409)
  check("POST /orders alice (inherited create)",    status(post("/orders", payload: ORDER_CREATE)),            201)
  check("POST /orders alice (inherited duplicate)", status(post("/orders", payload: ORDER_CREATE)),            409)

  puts "\n(4) CHANGE TTL in a subclass — proven by real expiry (orders #{GLOBAL_TTL}s vs payments #{PAYMENT_TTL}s)"
  check("POST /orders   alice (opens a #{GLOBAL_TTL}s claim)",  status(post("/orders", payload: ORDER_CREATE_TTL)),  201)
  check("POST /payments alice (opens a #{PAYMENT_TTL}s claim)", status(post("/payments", payload: PAYMENT_CREATE)),  201)
  check("POST /orders   alice (duplicate, inside #{GLOBAL_TTL}s)",  status(post("/orders", payload: ORDER_CREATE_TTL)), 409)
  check("POST /payments alice (duplicate, inside #{PAYMENT_TTL}s)", status(post("/payments", payload: PAYMENT_CREATE)), 409)
  first_wait = GLOBAL_TTL + 1
  puts "  ...waiting #{first_wait}s for the #{GLOBAL_TTL}s claim to expire (the #{PAYMENT_TTL}s one should not)..."
  sleep first_wait
  check("POST /orders   alice (its #{GLOBAL_TTL}s window expired -> allowed)", status(post("/orders", payload: ORDER_CREATE_TTL)), 201)
  check("POST /payments alice (its #{PAYMENT_TTL}s window still open -> blocked)", status(post("/payments", payload: PAYMENT_CREATE)), 409)
  second_wait = PAYMENT_TTL - first_wait + 1
  puts "  ...waiting #{second_wait}s more for the #{PAYMENT_TTL}s claim to expire..."
  sleep second_wait
  check("POST /payments alice (its #{PAYMENT_TTL}s window expired -> allowed)", status(post("/payments", payload: PAYMENT_CREATE)), 201)

  puts "\n(5) PER-CALLER scoping (same payload from a different caller is NOT a duplicate)"
  check("POST /payments alice (first)",                    status(post("/payments", payload: PAYMENT_MULTI, as: :alice)), 201)
  check("POST /payments alice (duplicate for alice)",      status(post("/payments", payload: PAYMENT_MULTI, as: :alice)), 409)
  check("POST /payments bob   (same payload, new caller)", status(post("/payments", payload: PAYMENT_MULTI, as: :bob)),   201)
  check("POST /payments carol (same payload, new caller)", status(post("/payments", payload: PAYMENT_MULTI, as: :carol)), 201)
  check("POST /payments bob   (duplicate for bob)",        status(post("/payments", payload: PAYMENT_MULTI, as: :bob)),   409)

  puts "\n(6) DIFFERENT payload, same caller (a different body is a different request, not a dup)"
  check("POST /widgets alice (red widget)",       status(post("/widgets", payload: WIDGET_RED)),   201)
  check("POST /widgets alice (green widget)",     status(post("/widgets", payload: WIDGET_GREEN)), 201) # different body
  check("POST /widgets alice (red widget again)", status(post("/widgets", payload: WIDGET_RED)),   409) # same body -> dup

  puts "\n(7) CONCURRENT in-flight duplicate (two #{SLOW_SECONDS}s requests at once -> exactly one wins)"
  outcomes = [:alice, :alice].map do |as|
    Thread.new { status(post("/slow", payload: SLOW_JOB, as: as)) }
  end.map(&:value).sort
  check("one request claimed, the other was rejected", outcomes, [201, 409])

  puts "\n(8) RELEASE ON FAILURE (a failed request frees the claim so a retry is allowed)"
  check("POST  /failures   alice (422, claim released)",  status(post("/failures", payload: FAIL_PAYLOAD)),    422)
  check("POST  /failures   alice (retry not blocked)",    status(post("/failures", payload: FAIL_PAYLOAD)),    422) # not 409
  check("PATCH /failures/1 alice (raises -> 500)",        status(patch("/failures/1", payload: FAIL_PAYLOAD)), 500)
  check("PATCH /failures/1 alice (retry not blocked)",    status(patch("/failures/1", payload: FAIL_PAYLOAD)), 500) # not 409

  puts "\n(9) GET / DELETE are never deduplicated (even though :index/:destroy are guarded by name)"
  check("GET    /reads   alice (first)",     status(request(:get, "/reads", as: :alice)),        200)
  check("GET    /reads   alice (again)",     status(request(:get, "/reads", as: :alice)),        200) # not 409
  check("DELETE /reads/1 alice (first)",     status(request(:delete, "/reads/1", as: :alice)),   200)
  check("DELETE /reads/1 alice (again)",     status(request(:delete, "/reads/1", as: :alice)),   200) # not 409

  puts "\n(10) 3xx REDIRECT keeps the claim (Post/Redirect/Get is a successful create)"
  check("POST /redirects alice (first -> 303)",      status(post("/redirects", payload: REDIRECT_PAYLOAD)), 303)
  check("POST /redirects alice (duplicate blocked)", status(post("/redirects", payload: REDIRECT_PAYLOAD)), 409)

  puts "\n(12) HOOKS fire as expected (enforce: on_duplicate_detected AND on_duplicate_rejected)"
  post("/hooked", payload: HOOK_PAYLOAD) # first claims; no hook fires
  check("POST /hooked alice (duplicate -> 409)", status(post("/hooked", payload: HOOK_PAYLOAD)), 409)
  hooked = hook_events.select { |e| e["path"] == "/hooked" }
  check("on_duplicate_detected fired once for /hooked", hooked.count { |e| e["hook"] == "detected" }, 1)
  check("on_duplicate_rejected fired once for /hooked", hooked.count { |e| e["hook"] == "rejected" }, 1)
  detected = hooked.find { |e| e["hook"] == "detected" } || {}
  check("detected hook carries action=create", detected["action"], "create")
  check("detected hook carries verb=POST",       detected["verb"], "POST")
  check("detected hook carries a fingerprint",   !detected["fingerprint"].to_s.empty?, true)
end

# ===========================================================================
# observe-mode server: scenario (11)
# ===========================================================================
with_server(OBSERVE_PORT, "DEDUPE_MODE" => "observe") do
  puts "\n(11) OBSERVE mode lets duplicates through (detected, but NOT rejected)"
  check("POST /payments alice (first)",                 status(post("/payments", payload: OBSERVE_PAYLOAD)), 201)
  check("POST /payments alice (duplicate -> allowed)",  status(post("/payments", payload: OBSERVE_PAYLOAD)), 201) # 201, not 409
  observed = hook_events.select { |e| e["path"] == "/payments" }
  check("observe: on_duplicate_detected DID fire",      observed.count { |e| e["hook"] == "detected" } >= 1, true)
  check("observe: on_duplicate_rejected did NOT fire",  observed.any? { |e| e["hook"] == "rejected" },       false)
end

# ===========================================================================
# custom-fingerprint server: scenario (13)
# ===========================================================================
with_server(FINGERPRINT_PORT, "DEDUPE_CUSTOM_FINGERPRINT" => "1") do
  puts "\n(13) FINGERPRINT override hook (custom fingerprint keys on verb+path only)"
  check("POST /widgets alice (body A)",                        status(post("/widgets", payload: WIDGET_RED)),               201)
  check("POST /widgets alice (different body B -> still dup)", status(post("/widgets", payload: WIDGET_GREEN)),             409) # body ignored
  check("POST /widgets bob   (different caller -> still dup)", status(post("/widgets", payload: WIDGET_CREATE, as: :bob)),  409) # caller ignored
  fp = hook_events.select { |e| e["hook"] == "fingerprint" && e["path"] == "/widgets" }
  check("custom fingerprint hook was invoked per request", fp.size, 3)
end

# ===========================================================================
# custom-caller_id server: scenario (14)
# ===========================================================================
with_server(CALLER_ID_PORT, "DEDUPE_CUSTOM_CALLER_ID" => "1") do
  puts "\n(14) CALLER_ID override hook (identity comes from X-Api-Key, not Authorization)"
  # Same X-Api-Key + same body, but DIFFERENT Authorization: a duplicate, which only
  # happens if caller_id reads X-Api-Key (the default would have used Authorization).
  check("POST /widgets api_key=k1 alice (first)",            status(post("/widgets", payload: WIDGET_RED, as: :alice, api_key: "k1")), 201)
  check("POST /widgets api_key=k1 bob   (diff auth -> dup)", status(post("/widgets", payload: WIDGET_RED, as: :bob,   api_key: "k1")), 409)
  check("POST /widgets api_key=k2 alice (diff key -> new caller)", status(post("/widgets", payload: WIDGET_RED, as: :alice, api_key: "k2")), 201)
  ci = hook_events.select { |e| e["hook"] == "caller_id" && e["path"] == "/widgets" }
  check("custom caller_id hook was invoked per request",     ci.size, 3)
  check("custom caller_id hook saw the X-Api-Key value",     ci.map { |e| e["key"] }.uniq.sort, %w[k1 k2])
end

# ===========================================================================
puts "\n#{'-' * 78}"
if FAILURES.empty?
  puts "PASS - all checks green"
  exit 0
else
  puts "FAIL - #{FAILURES.size} check(s) failed:"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
