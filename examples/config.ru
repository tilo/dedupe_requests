# frozen_string_literal: true
#
# A real Rails API service that exercises every dedupe_requests feature, booted
# as a REAL HTTP server (Puma) for examples/end_to_end_test.rb.
#
# Run it standalone to poke at it by hand:
#
#   redis-server &                                    # needs a running Redis
#   bundle exec puma examples/config.ru -p 9292       # boot the server
#
#   curl -i -XPOST localhost:9292/widgets -d '{"a":1}' -H 'content-type: application/json'  # 201
#   curl -i -XPOST localhost:9292/widgets -d '{"a":1}' -H 'content-type: application/json'  # 409 (duplicate)
#
# The controllers below form one inheritance tree off ApplicationController. A
# single boot covers the inheritance features and the request-lifecycle behavior:
#
#   (1) baseline at the application-controller level   -> WidgetsController (declares nothing)
#   (2) skipping a baseline action in a subclass        -> DraftsController  (skip: [:create])
#   (3) adding an action in a subclass                  -> OrdersController  (on: [:approve])
#   (4) changing the TTL in a subclass                  -> PaymentsController (on: [:create], ttl)
#   - a slow action (for the concurrent in-flight test) -> SlowController
#   - actions that fail / raise (claim is released)     -> FailuresController
#   - GET/DELETE actions guarded by name (never deduped) -> ReadController
#   - a 3xx redirect (claim is kept)                    -> RedirectsController
#
# DEDUPE_MODE selects :enforce (default) or :observe so the test can boot a second
# server to check observe-mode pass-through.

require "logger" # ActiveSupport < 7.1 references ::Logger before requiring it
require "securerandom"
require "action_controller"
require "action_dispatch"
require "redis"
require_relative "../lib/dedupe_requests"

# Short TTLs on purpose: the integration test proves the TTL difference by waiting
# for the shorter window to expire while the longer one is still open.
GLOBAL_TTL  = Integer(ENV.fetch("DEDUPE_TTL", "2"))
PAYMENT_TTL = Integer(ENV.fetch("DEDUPE_PAYMENT_TTL", "5"))

# Test instrumentation: every hook invocation is appended here (one Puma process,
# many threads, so a Mutex is enough), and exposed at GET /_hooks so the test can
# assert — over HTTP — that the right hooks fired with the right data.
HOOK_EVENTS = []
HOOK_MUTEX  = Mutex.new
def record_hook(event)
  HOOK_MUTEX.synchronize { HOOK_EVENTS << event }
end

DedupeRequests.configure do |c|
  c.redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/15"))
  c.mode  = ENV.fetch("DEDUPE_MODE", "enforce").to_sym
  c.ttl   = GLOBAL_TTL
  # caller_id is left at its default, which derives the caller identity from the
  # request's Authorization header. The integration test sends a different
  # `Authorization: Bearer <token>` per simulated caller, so the same payload from
  # two different callers fingerprints differently and is NOT treated as a duplicate.

  # Record the duplicate-notification hooks. on_duplicate_detected fires whenever a
  # duplicate is seen (observe AND enforce); on_duplicate_rejected fires only when a
  # duplicate is actually rejected (enforce mode).
  c.on_duplicate_detected = ->(info) { record_hook(info.merge(hook: "detected")) }
  c.on_duplicate_rejected = ->(info) { record_hook(info.merge(hook: "rejected")) }

  # When asked, replace the whole fingerprint with a custom one that keys only on
  # verb + path + query (ignoring caller AND body), so the test can prove the
  # override took effect: two different bodies — or two different callers — now
  # collide. It also records that the hook was invoked.
  if ENV["DEDUPE_CUSTOM_FINGERPRINT"] == "1"
    c.fingerprint = lambda do |request|
      record_hook(hook: "fingerprint", path: request.path, verb: request.request_method)
      "#{request.request_method}:#{request.path}?#{request.query_string}"
    end
  end

  # When asked, replace caller_id with a custom one that identifies the caller by
  # an X-Api-Key header (ignoring the Authorization header the default would use),
  # so the test can prove this callable is what drives the per-caller scoping. It
  # also records that the hook was invoked.
  if ENV["DEDUPE_CUSTOM_CALLER_ID"] == "1"
    c.caller_id = lambda do |controller|
      key = controller.request.get_header("HTTP_X_API_KEY")
      record_hook(hook: "caller_id", path: controller.request.path, key: key)
      key
    end
  end
end

# Most actions just return 201 with a unique id, tagged with the resource name so
# a manual curl shows which controller answered.
module RenderOk
  def render_ok(resource, extra = {})
    render json: { ok: true, id: SecureRandom.uuid, resource: resource }.merge(extra), status: :created
  end
end

# (1) Application-controller level: the baseline lives here. Every subclass
#     inherits it, including ones that declare nothing of their own.
class ApplicationController < ActionController::API
  include RenderOk
  include DedupeRequests::Controller
  dedupe_requests on: %i[create update]
end

# Declares NOTHING — proves the baseline reaches a bare subclass. The GET #index
# is reached below to show GET is never deduplicated.
class WidgetsController < ApplicationController
  def create
    render_ok("widget")
  end

  def update
    render_ok("widget")
  end

  def index
    render json: { widgets: [] }, status: :ok
  end
end

# (3) Adds :approve on top of the inherited create/update.
class OrdersController < ApplicationController
  dedupe_requests on: [:approve]

  def create
    render_ok("order")
  end

  def update
    render_ok("order")
  end

  def approve
    render_ok("order", approved: true)
  end
end

# (2) Skips :create from the baseline; :update stays guarded.
class DraftsController < ApplicationController
  dedupe_requests skip: [:create]

  def create
    render_ok("draft")
  end

  def update
    render_ok("draft")
  end
end

# (4) Overrides the TTL for :create only (PAYMENT_TTL instead of GLOBAL_TTL).
class PaymentsController < ApplicationController
  dedupe_requests on: [:create], ttl: PAYMENT_TTL

  def create
    render_ok("payment")
  end
end

# A deliberately slow action so the test can fire two requests that are genuinely
# in flight at the same time. :create is guarded by the inherited baseline.
class SlowController < ApplicationController
  def create
    sleep Float(ENV.fetch("DEDUPE_SLOW_SECONDS", "1"))
    render_ok("slow")
  end
end

# Failing actions. The claim is released on a 4xx/5xx response (#create) or a
# raised exception (#update), so an identical retry is NOT blocked.
class FailuresController < ApplicationController
  def create
    render json: { error: "unprocessable" }, status: :unprocessable_entity
  end

  def update
    raise "simulated failure"
  end
end

# Actions guarded BY NAME, but reached via GET/DELETE — which the gem never
# deduplicates. Repeats are allowed even though :index/:destroy are in the set.
class ReadController < ApplicationController
  dedupe_requests on: %i[index destroy]

  def index
    render json: { items: [] }, status: :ok
  end

  def destroy
    render json: { deleted: true }, status: :ok
  end
end

# A 3xx redirect (Post/Redirect/Get) is treated as a successful create, so the
# claim is KEPT and a duplicate is still blocked. :create is baseline-guarded.
class RedirectsController < ApplicationController
  def create
    redirect_to "/widgets", status: :see_other
  end
end

# A clean guarded endpoint used only by the hooks scenario, so its recorded
# detected/rejected events are unambiguous. :create is baseline-guarded.
class HookedController < ApplicationController
  def create
    render_ok("hooked")
  end
end

# Test-only: exposes the recorded hook invocations so the test can read them over
# HTTP. Not part of the dedupe demo — it just reports what the hooks captured.
class DebugController < ActionController::API
  def hooks
    render json: { events: HOOK_EVENTS }, status: :ok
  end
end

ROUTES = ActionDispatch::Routing::RouteSet.new
ROUTES.draw do
  post   "/widgets"            => "widgets#create"
  patch  "/widgets/:id"        => "widgets#update"
  get    "/widgets"            => "widgets#index"

  post   "/orders"             => "orders#create"
  patch  "/orders/:id"         => "orders#update"
  post   "/orders/:id/approve" => "orders#approve"

  post   "/drafts"             => "drafts#create"
  patch  "/drafts/:id"         => "drafts#update"

  post   "/payments"           => "payments#create"

  post   "/slow"               => "slow#create"

  post   "/failures"           => "failures#create"
  patch  "/failures/:id"       => "failures#update"

  get    "/reads"              => "read#index"
  delete "/reads/:id"          => "read#destroy"

  post   "/redirects"          => "redirects#create"

  post   "/hooked"             => "hooked#create"

  get    "/_hooks"             => "debug#hooks"
end

run ROUTES
