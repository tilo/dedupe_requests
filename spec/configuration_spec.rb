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

  it "threads config.logger into the auto-built store (logged on a Redis error)" do
    logger = double("logger")
    expect(logger).to receive(:warn).with(/redis error/)
    config.logger = logger
    config.redis = Class.new do
      def with
        raise "down"
      end
    end.new
    expect(config.store.claim("fp", ttl: 1)).to eq(:error)
  end

  it "has no default caller_id (you must configure one)" do
    expect(config.caller_id).to be_nil
  end
end
