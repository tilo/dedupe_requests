# frozen_string_literal: true

RSpec.describe DedupeRequests::Configuration do
  subject(:config) { described_class.new }

  it "defaults mode to :enforce" do
    expect(config.mode).to eq(:enforce)
  end

  it "defaults ttl to 90 seconds" do
    expect(config.ttl).to eq(90)
  end

  it "defaults digest to :sha256" do
    expect(config.digest).to eq(:sha256)
  end

  it "defaults conflict_status to 409" do
    expect(config.conflict_status).to eq(409)
  end

  it "defaults the namespace" do
    expect(config.namespace).to eq("dedupe_requests")
  end

  it "is enabled unless mode is :off" do
    expect(config).to be_enabled
    config.mode = :off
    expect(config).not_to be_enabled
  end

  it "validates the mode" do
    expect { config.mode = :bogus }.to raise_error(ArgumentError)
    config.mode = :observe
    expect(config.mode).to eq(:observe)
  end

  it "builds a RedisStore from a redis client" do
    config.redis = FakeRedis.new
    expect(config.store).to be_a(DedupeRequests::RedisStore)
  end

  it "has no store without a redis or an injected store" do
    expect(config.store).to be_nil
  end

  it "uses an injected store as-is" do
    store = double("store")
    config.store = store
    expect(config.store).to be(store)
  end

  it "returns a custom conflict_body when one is set" do
    config.conflict_body = { "x" => 1 }
    expect(config.conflict_body).to eq("x" => 1)
  end

  describe "DEFAULT_CALLER_ID" do
    def request_with(headers: {}, cookies: {})
      RequestDouble.new(
        request_method: "POST", path: "/x", query_string: "", raw_post: "",
        headers: headers, cookies: cookies
      )
    end

    it "uses the Authorization header when present" do
      id = described_class::DEFAULT_CALLER_ID.call(request_with(headers: { "HTTP_AUTHORIZATION" => "Bearer z" }))
      expect(id).to eq("Bearer z")
    end

    it "falls back to a Rails-style session cookie" do
      id = described_class::DEFAULT_CALLER_ID.call(request_with(cookies: { "_myapp_session" => "abc" }))
      expect(id).to eq("abc")
    end

    it "is nil when neither identity signal is present" do
      expect(described_class::DEFAULT_CALLER_ID.call(request_with)).to be_nil
    end

    it "skips the Authorization check when the request has no get_header" do
      obj = Object.new
      def obj.cookies = { "_app_session" => "ck" }
      expect(described_class::DEFAULT_CALLER_ID.call(obj)).to eq("ck")
    end

    it "returns nil when the request supports no cookies and has no auth" do
      obj = Object.new
      def obj.get_header(_name) = nil
      expect(described_class::DEFAULT_CALLER_ID.call(obj)).to be_nil
    end

    it "ignores cookies that are not a session cookie" do
      expect(described_class::DEFAULT_CALLER_ID.call(request_with(cookies: { "tracking" => "x" }))).to be_nil
    end
  end
end
