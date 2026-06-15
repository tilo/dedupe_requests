# frozen_string_literal: true

RSpec.describe DedupeRequests::RedisStore do
  let(:redis) { FakeRedis.new }
  subject(:store) { described_class.new(redis, namespace: "t") }

  it "claims a fresh fingerprint and returns a token" do
    expect(store.claim("fp", ttl: 60)).to be_a(String)
  end

  it "returns false for a duplicate claim" do
    store.claim("fp", ttl: 60)
    expect(store.claim("fp", ttl: 60)).to be(false)
  end

  it "namespaces the key" do
    expect(store.key("abc")).to eq("t:dedup:abc")
  end

  it "releases only when the token matches (token-safe)" do
    token = store.claim("fp", ttl: 60)

    store.release("fp", "wrong-token")
    expect(store.claim("fp", ttl: 60)).to be(false) # still held

    store.release("fp", token)
    expect(store.claim("fp", ttl: 60)).to be_a(String) # now free
  end

  it "wraps a bare client so a connection pool also works" do
    pool = Class.new do
      def initialize(redis)
        @redis = redis
      end

      def with
        yield @redis
      end
    end.new(redis)
    pooled = described_class.new(pool, namespace: "t")
    expect(pooled.claim("fp", ttl: 60)).to be_a(String)
  end

  it "fails open (returns :error) when redis raises" do
    boom = Class.new do
      def with
        raise "redis down"
      end
    end.new
    expect(described_class.new(boom).claim("fp", ttl: 60)).to eq(:error)
  end

  it "logs via the configured logger when redis raises" do
    logger = double("logger")
    expect(logger).to receive(:warn).with(/redis error/)
    boom = Class.new do
      def with
        raise "down"
      end
    end.new
    expect(described_class.new(boom, logger: logger).claim("fp", ttl: 60)).to eq(:error)
  end

  it "release returns false (rescued) when redis raises" do
    boom = Class.new do
      def with
        raise "down"
      end
    end.new
    expect(described_class.new(boom).release("fp", "tok")).to be(false)
  end
end
