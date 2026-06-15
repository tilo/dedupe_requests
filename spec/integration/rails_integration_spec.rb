# frozen_string_literal: true

require "spec_helper"
require "action_controller"
require "action_dispatch"
require "rack/test"
require "mock_redis"
require "json"

# A real ActionController + ActionDispatch routing stack (a minimal "dummy app"),
# driven over HTTP with Rack::Test, backed by the mock_redis gem so no Redis
# server is needed.
#
# NOTE on scope: mock_redis does not execute Lua, so the token-safe RELEASE
# (which runs only on a non-2xx response or a raised exception) is exercised in
# the unit/concern specs (which use an in-memory double that implements the
# script, and which run the same code against a real Redis). These integration
# tests cover the claim path: success, duplicate 409, observe pass-through, GET
# skipping, and per-caller scoping.
RSpec.describe "Rails integration" do
  include Rack::Test::Methods

  ActionController::Base.allow_forgery_protection = false

  class DummyApplicationController < ActionController::Base
    include DedupeRequests::Controller
    dedupe_requests only: %i[create update]
  end

  class WidgetsController < DummyApplicationController
    def create
      render json: { ok: true }, status: :created
    end

    def update
      render json: { ok: true }, status: :ok
    end

    def index
      render json: { list: [] }, status: :ok
    end
  end

  DUMMY_ROUTES = ActionDispatch::Routing::RouteSet.new
  DUMMY_ROUTES.draw do
    post  "/widgets"     => "widgets#create"
    patch "/widgets/:id" => "widgets#update"
    get   "/widgets"     => "widgets#index"
  end

  def app
    DUMMY_ROUTES
  end

  let(:redis) { MockRedis.new }

  before do
    DedupeRequests.configure do |c|
      c.redis = redis
      c.namespace = "test"
    end
  end

  def post_json(path, body, headers = {})
    post path, body, { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  it "processes the first POST normally" do
    post_json "/widgets", '{"amount":10}'
    expect(last_response.status).to eq(201)
    expect(JSON.parse(last_response.body)).to eq("ok" => true)
  end

  it "rejects an identical duplicate POST with 409" do
    post_json "/widgets", '{"amount":10}'
    post_json "/widgets", '{"amount":10}'

    expect(last_response.status).to eq(409)
    expect(last_response.headers["X-Dedupe-Request"]).to eq("true")
    body = JSON.parse(last_response.body)
    expect(body["errors"].first["category"]).to eq("duplicate_operation")
  end

  it "does not treat a different body as a duplicate" do
    post_json "/widgets", '{"amount":10}'
    post_json "/widgets", '{"amount":20}'
    expect(last_response.status).to eq(201)
  end

  it "scopes duplicates per caller (different Authorization → independent)" do
    post_json "/widgets", '{"amount":10}', "HTTP_AUTHORIZATION" => "Bearer aaa"
    post_json "/widgets", '{"amount":10}', "HTTP_AUTHORIZATION" => "Bearer bbb"
    expect(last_response.status).to eq(201)
  end

  it "ignores a client-supplied Idempotency-Key header (same body is still a duplicate)" do
    post_json "/widgets", '{"amount":10}', "HTTP_IDEMPOTENCY_KEY" => "key-1"
    post_json "/widgets", '{"amount":10}', "HTTP_IDEMPOTENCY_KEY" => "key-2"
    expect(last_response.status).to eq(409)
  end

  it "dedupes PATCH (update) too" do
    patch "/widgets/1", '{"x":1}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    patch "/widgets/1", '{"x":1}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(409)
  end

  it "never dedupes GET, even when repeated" do
    get "/widgets"
    expect(last_response.status).to eq(200)
    get "/widgets"
    expect(last_response.status).to eq(200)
  end

  it "lets a duplicate through (no 409) in observe mode" do
    DedupeRequests.config.mode = :observe
    post_json "/widgets", '{"amount":10}'
    post_json "/widgets", '{"amount":10}'
    expect(last_response.status).to eq(201)
  end

  it "emits the duplicate hooks in a real request cycle" do
    events = []
    DedupeRequests.config.on_duplicate_detected = ->(info) { events << [:detected, info[:action], info[:verb]] }
    DedupeRequests.config.on_duplicate_rejected = ->(info) { events << [:rejected, info[:action], info[:verb]] }

    post_json "/widgets", '{"amount":10}'
    post_json "/widgets", '{"amount":10}'

    expect(events).to eq([[:detected, "create", "POST"], [:rejected, "create", "POST"]])
  end
end
