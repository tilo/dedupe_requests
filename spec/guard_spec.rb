# frozen_string_literal: true

RSpec.describe DedupeRequests::Guard do
  let(:config) { DedupeRequests::Configuration.new.tap { |c| c.redis = FakeRedis.new } }
  subject(:guard) { described_class.new(config) }

  def req(method: "POST", body: "{}")
    RequestDouble.new(
      request_method: method, path: "/orders", query_string: "", raw_post: body,
      headers: {}, cookies: {}
    )
  end

  it "claims the first request" do
    expect(guard.claim(req).outcome).to eq(:claimed)
  end

  it "flags an identical second request as a duplicate" do
    guard.claim(req)
    expect(guard.claim(req).outcome).to eq(:duplicate)
  end

  it "skips non-mutating verbs" do
    expect(guard.claim(req(method: "GET")).outcome).to eq(:skip)
    expect(guard.claim(req(method: "DELETE")).outcome).to eq(:skip)
  end

  it "skips when mode is off" do
    config.mode = :off
    expect(guard.claim(req).outcome).to eq(:skip)
  end

  it "fails open (skip) when the store reports a redis error" do
    config.store = Class.new { def claim(*, **) = :error }.new
    expect(guard.claim(req).outcome).to eq(:skip)
  end

  it "releases a claimed fingerprint so it can be claimed again" do
    result = guard.claim(req)
    expect(guard.release(result)).to be_truthy
    expect(guard.claim(req).outcome).to eq(:claimed)
  end

  it "does not release a duplicate or skip result" do
    expect(guard.release(DedupeRequests::Guard::Result.new(:duplicate, "fp"))).to be(false)
    expect(guard.release(DedupeRequests::Guard::Result.new(:skip))).to be(false)
  end

  it "skips when no store is configured" do
    bare = DedupeRequests::Configuration.new
    expect(described_class.new(bare).claim(req).outcome).to eq(:skip)
  end
end
