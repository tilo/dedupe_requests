# frozen_string_literal: true

RSpec.describe DedupeRequests::Controller do
  # Minimal Rails-controller stand-in that includes the REAL concern. It provides
  # the controller surface the concern touches (request/response/render/etc.) so
  # the around behavior can be exercised without booting a full Rails stack.
  class FakeResponse
    attr_accessor :status

    def initialize
      @status = 200
      @headers = {}
    end

    def set_header(key, value)
      @headers[key] = value
    end

    attr_reader :headers
  end

  class FakeController
    def self.around_action(*); end # concern registers here; tests invoke the method directly

    include DedupeRequests::Controller

    attr_reader :request, :response, :rendered

    def initialize(action:, request:)
      @action_name = action
      @request = request
      @response = FakeResponse.new
      @rendered = nil
    end

    def action_name
      @action_name
    end

    def controller_name
      "orders"
    end

    def render(opts)
      @rendered = opts
      @response.status = opts[:status] || 200
    end
  end

  def req(body: "{}")
    RequestDouble.new(
      request_method: "POST", path: "/orders", query_string: "", raw_post: body,
      headers: {}, cookies: {}
    )
  end

  before { DedupeRequests.configure { |c| c.redis = FakeRedis.new } }

  # An isolated controller class per call, so class-level state doesn't leak.
  def controller_class(**dsl)
    Class.new(FakeController) { dedupe_requests(**dsl) }
  end

  # Runs the around hook; returns whether the action body ran.
  def run(controller)
    ran = false
    controller.send(:dedupe_requests_around) { ran = true }
    ran
  end

  describe "the de-dupe set DSL (only/also/skip)" do
    it "only: sets the exact action list" do
      expect(controller_class(only: %i[create update]).dedupe_requests_actions)
        .to contain_exactly(:create, :update)
    end

    it "also: adds to the inherited baseline" do
      base = controller_class(only: %i[create update])
      sub = Class.new(base) { dedupe_requests also: %i[approve] }
      expect(sub.dedupe_requests_actions).to contain_exactly(:create, :update, :approve)
    end

    it "skip: subtracts from the inherited baseline" do
      base = controller_class(only: %i[create update])
      sub = Class.new(base) { dedupe_requests skip: %i[create] }
      expect(sub.dedupe_requests_actions).to contain_exactly(:update)
    end

    it "skip_dedupe_requests removes inherited actions" do
      base = controller_class(only: %i[create update])
      sub = Class.new(base) { skip_dedupe_requests only: %i[update] }
      expect(sub.dedupe_requests_actions).to contain_exactly(:create)
    end

    it "does not mutate the parent's set when a subclass adjusts it" do
      base = controller_class(only: %i[create update])
      Class.new(base) { dedupe_requests skip: %i[create] }
      expect(base.dedupe_requests_actions).to contain_exactly(:create, :update)
    end
  end

  describe "around behavior" do
    it "runs the action and does nothing for an action outside the set" do
      controller = controller_class(only: %i[create]).new(action: "index", request: req)
      expect(run(controller)).to be(true)
      expect(controller.rendered).to be_nil
    end

    it "processes the first request" do
      controller = controller_class(only: %i[create]).new(action: "create", request: req)
      expect(run(controller)).to be(true)
      expect(controller.rendered).to be_nil
    end

    it "rejects an identical duplicate with 409 in enforce mode and skips the action" do
      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req))
      dup = klass.new(action: "create", request: req)

      expect(run(dup)).to be(false)
      expect(dup.response.status).to eq(409)
      expect(dup.rendered[:json]).to eq(DedupeRequests.config.conflict_body)
      expect(dup.response.headers["X-Dedupe-Request"]).to eq("true")
    end

    it "lets a duplicate through (no 409) in observe mode" do
      DedupeRequests.config.mode = :observe
      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req))
      dup = klass.new(action: "create", request: req)

      expect(run(dup)).to be(true)
      expect(dup.rendered).to be_nil
    end

    it "in observe mode, detects the duplicate (fires detected, NOT rejected) yet still runs the action" do
      DedupeRequests.config.mode = :observe
      events = []
      DedupeRequests.config.on_duplicate_detected = ->(_info) { events << :detected }
      DedupeRequests.config.on_duplicate_rejected = ->(_info) { events << :rejected }

      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req)) # first → claimed, no hook
      dup = klass.new(action: "create", request: req)

      expect(run(dup)).to be(true)        # duplicate still runs the action
      expect(dup.rendered).to be_nil      # no 409
      expect(events).to eq([:detected])   # detected fired; rejected did NOT
    end

    it "releases the fingerprint on a non-2xx response so a retry is allowed" do
      klass = controller_class(only: %i[create])
      first = klass.new(action: "create", request: req)
      first.send(:dedupe_requests_around) { first.response.status = 500 }

      retried = klass.new(action: "create", request: req)
      expect(run(retried)).to be(true)
      expect(retried.rendered).to be_nil
    end

    it "releases the fingerprint when the action raises" do
      klass = controller_class(only: %i[create])
      boom = klass.new(action: "create", request: req)
      expect { boom.send(:dedupe_requests_around) { raise "boom" } }.to raise_error("boom")

      retried = klass.new(action: "create", request: req)
      expect(run(retried)).to be(true)
    end

    it "keeps the fingerprint on a 2xx so a real duplicate is still blocked" do
      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req)) # 200 by default
      dup = klass.new(action: "create", request: req)
      expect(run(dup)).to be(false)
    end

    it "emits duplicate_detected and duplicate_rejected hooks" do
      events = []
      DedupeRequests.config.on_duplicate_detected = ->(info) { events << [:detected, info[:action]] }
      DedupeRequests.config.on_duplicate_rejected = ->(info) { events << [:rejected, info[:action]] }

      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req))
      run(klass.new(action: "create", request: req))

      expect(events).to eq([[:detected, "create"], [:rejected, "create"]])
    end

    it "passes the full payload (all five keys) to the hooks" do
      captured = nil
      DedupeRequests.config.on_duplicate_detected = ->(info) { captured = info }

      klass = controller_class(only: %i[create])
      run(klass.new(action: "create", request: req))
      run(klass.new(action: "create", request: req))

      expect(captured).to match(
        fingerprint: a_string_matching(/\A[0-9a-f]{64}\z/),
        controller: "orders",
        action: "create",
        verb: "POST",
        path: "/orders"
      )
    end
  end

  describe "edge cases" do
    it "processes the request (no 409) when the store reports redis down (fail open)" do
      DedupeRequests.config.store = Class.new { def claim(*, **) = :error }.new
      controller = controller_class(only: %i[create]).new(action: "create", request: req)
      expect(run(controller)).to be(true)
      expect(controller.rendered).to be_nil
    end

    it "does nothing when mode is :off" do
      DedupeRequests.config.mode = :off
      controller = controller_class(only: %i[create]).new(action: "create", request: req)
      expect(run(controller)).to be(true)
      expect(controller.rendered).to be_nil
    end

    it "does nothing in a controller that never called dedupe_requests" do
      controller = Class.new(FakeController).new(action: "create", request: req)
      expect(run(controller)).to be(true)
    end

    it "passes a per-controller ttl override through to the store" do
      spy = Class.new do
        attr_reader :ttl

        def claim(_fingerprint, ttl:)
          @ttl = ttl
          "tok"
        end

        def release(*, **)
          true
        end
      end.new
      DedupeRequests.config.store = spy

      run(controller_class(only: %i[create], ttl: 30).new(action: "create", request: req))

      expect(spy.ttl).to eq(30)
    end
  end
end
