# frozen_string_literal: true

require "spec_helper"
require "action_controller"
require "action_dispatch"
require "rack/test"
require "redis"
require "json"

# Full end-to-end: a real ActionController + ActionDispatch stack over HTTP,
# backed by a REAL Redis — so the token-safe release Lua script actually runs.
# This is the only place the release-on-failure path is exercised end-to-end
# (mock_redis can't execute Lua).
#
# Requires a running Redis (set REDIS_URL to override the default).
RSpec.describe "Rails end-to-end with real Redis" do
  include Rack::Test::Methods

  ActionController::Base.allow_forgery_protection = false

  class RealAppController < ActionController::Base
    include DedupeRequests::Controller
    dedupe_requests only: %i[create flaky boom redirected]

    def create
      render json: { ok: true }, status: :created
    end

    def redirected
      redirect_to "/things", status: :see_other
    end

    def flaky
      render json: { error: true }, status: :unprocessable_entity
    end

    def boom
      raise "kaboom"
    end
  end

  REAL_ROUTES = ActionDispatch::Routing::RouteSet.new
  REAL_ROUTES.draw do
    post "/things" => "real_app#create"
    post "/flaky"  => "real_app#flaky"
    post "/boom"   => "real_app#boom"
    post "/redirected" => "real_app#redirected"
  end

  def app
    REAL_ROUTES
  end

  redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")
  let(:redis) { Redis.new(url: redis_url) }

  before do
    redis.flushdb
    DedupeRequests.configure do |c|
      c.redis = redis
      c.namespace = "real_e2e"
    end
  end

  after { redis.flushdb }

  def post_json(path)
    post path, "{}", "CONTENT_TYPE" => "application/json"
  end

  it "claim survives a 2xx, so a real duplicate is rejected with 409" do
    post_json "/things"
    expect(last_response.status).to eq(201)
    post_json "/things"
    expect(last_response.status).to eq(409)
  end

  it "releases via the real Lua after a non-2xx, so an identical retry is NOT blocked" do
    post_json "/flaky"
    expect(last_response.status).to eq(422)
    post_json "/flaky"
    expect(last_response.status).to eq(422) # 422 again (not 409) → the fingerprint was released
  end

  it "releases via the real Lua after a raised exception, so an identical retry is NOT blocked" do
    expect { post_json "/boom" }.to raise_error(/kaboom/)
    expect { post_json "/boom" }.to raise_error(/kaboom/) # raises again (not a 409) → released
  end

  it "keeps the fingerprint on a 3xx redirect (Post/Redirect/Get), so a duplicate IS blocked" do
    post_json "/redirected"
    expect(last_response.status).to eq(303)
    post_json "/redirected"
    expect(last_response.status).to eq(409) # 3xx kept the claim → duplicate rejected
  end
end
