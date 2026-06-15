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

    def initialize(action:, request:, caller: nil)
      @action_name = action
      @request = request
      @caller = caller
      @response = FakeResponse.new
      @rendered = nil
    end

    def current_caller
      @caller
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

  describe "the de-dupe set DSL (only/skip)" do
    it "only: sets the exact action list" do
      expect(controller_class(only: %i[create update]).dedupe_requests_actions)
        .to contain_exactly(:create, :update)
    end

    it "only: in a subclass adds to the inherited set" do
      base = controller_class(only: %i[create update])
      sub = Class.new(base) { dedupe_requests only: %i[approve] }
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

    it "treats skip: of a never-guarded action as a harmless no-op (across inheritance)" do
      app = Class.new(FakeController) { dedupe_requests only: [:create] }
      sub = Class.new(app) { dedupe_requests skip: [:update] } # update was never guarded

      expect(sub.dedupe_requests_actions).to contain_exactly(:create)

      # create is still deduped in the subclass — the stray skip didn't break it
      run(sub.new(action: "create", request: req))
      dup = sub.new(action: "create", request: req)
      expect(run(dup)).to be(false)
    end
  end

  describe "around behavior" do
    it "runs the action and does nothing for an action outside the set" do
      controller = controller_class(only: %i[create]).new(action: "index", request: req)
      expect(run(controller)).to be(true)
      expect(controller.rendered).to be_nil
    end

    it "does not dedupe an action removed with skip: (no dedupe at all)" do
      klass = Class.new(FakeController) do
        dedupe_requests only: %i[create update]
        dedupe_requests skip: [:create]
      end
      run(klass.new(action: "create", request: req))
      dup = klass.new(action: "create", request: req)
      expect(run(dup)).to be(true) # create was skipped → never deduped, runs again
      expect(dup.rendered).to be_nil
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

    it "keeps the fingerprint on a 3xx redirect (Post/Redirect/Get) so a duplicate is still blocked" do
      klass = controller_class(only: %i[create])
      first = klass.new(action: "create", request: req)
      first.send(:dedupe_requests_around) { first.response.status = 303 }

      dup = klass.new(action: "create", request: req)
      expect(run(dup)).to be(false) # 303 kept the claim → duplicate blocked
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
      DedupeRequests.config.store = Class.new do
        def claim(*_args, **_opts)
          :error
        end
      end.new
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

    it "resolves caller_id from the controller and scopes dedupe per caller" do
      DedupeRequests.config.caller_id = ->(controller) { controller.current_caller }
      klass = controller_class(only: %i[create])

      run(klass.new(action: "create", request: req, caller: "u1"))
      same = klass.new(action: "create", request: req, caller: "u1")
      expect(run(same)).to be(false) # same caller + body → duplicate

      other = klass.new(action: "create", request: req, caller: "u2")
      expect(run(other)).to be(true) # different caller → independent
    end

    it "works when caller_id is disabled (nil)" do
      DedupeRequests.config.caller_id = nil
      controller = controller_class(only: %i[create]).new(action: "create", request: req)
      expect(run(controller)).to be(true)
    end
  end

  # Per-action TTL: each `dedupe_requests` line attaches its `ttl:` to exactly the
  # actions it names; lines accumulate; resolution per action is its own TTL, then
  # the global config.ttl.
  describe "per-action TTL" do
    # Captures the ttl the store actually receives for a given action.
    def captured_ttl_for(klass, action)
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
      klass.new(action: action.to_s, request: req).send(:dedupe_requests_around) {}
      spy.ttl
    end

    # Top-level baseline: create/update guarded with TTL 90.
    let(:app_controller) { Class.new(FakeController) { dedupe_requests only: %i[create update], ttl: 90 } }

    it "applies one line's TTL to every action named on that line" do
      klass = Class.new(FakeController) { dedupe_requests only: %i[create update], ttl: 120 }
      expect(captured_ttl_for(klass, :create)).to eq(120)
      expect(captured_ttl_for(klass, :update)).to eq(120)
    end

    it "gives each action its own TTL when declared on separate lines" do
      klass = Class.new(FakeController) do
        dedupe_requests only: [:create], ttl: 120
        dedupe_requests only: [:update], ttl: 180
      end
      expect(captured_ttl_for(klass, :create)).to eq(120)
      expect(captured_ttl_for(klass, :update)).to eq(180)
    end

    it "inherits per-action TTLs from a parent controller" do
      sub = Class.new(app_controller)
      expect(captured_ttl_for(sub, :create)).to eq(90)
      expect(captured_ttl_for(sub, :update)).to eq(90)
    end

    it "lets a subclass change the TTL by re-declaring the actions" do
      sub = Class.new(app_controller) { dedupe_requests only: %i[create update], ttl: 30 }
      expect(captured_ttl_for(sub, :create)).to eq(30)
      expect(captured_ttl_for(sub, :update)).to eq(30)
    end

    it "lets a subclass override one action's TTL, leaving the others inherited" do
      sub = Class.new(app_controller) { dedupe_requests only: [:update], ttl: 180 }
      expect(captured_ttl_for(sub, :create)).to eq(90)  # inherited
      expect(captured_ttl_for(sub, :update)).to eq(180) # overridden
    end

    it "falls back to the global config TTL when a line has no ttl" do
      DedupeRequests.config.ttl = 120
      plain = Class.new(FakeController) { dedupe_requests only: [:create] }
      expect(captured_ttl_for(plain, :create)).to eq(120)
    end
  end
end
