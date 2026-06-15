# frozen_string_literal: true

require "spec_helper"
require "redis"

# Exercises RedisStore against a REAL Redis, so the token-safe release Lua script
# actually runs. Uses db 15 and flushes it around each example.
#
# Requires a running Redis (set REDIS_URL to override the default).
RSpec.describe "DedupeRequests::RedisStore against a real Redis" do
  redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")

  let(:redis) { Redis.new(url: redis_url) }
  subject(:store) { DedupeRequests::RedisStore.new(redis, namespace: "dedupe_test") }

  before { redis.flushdb }
  after  { redis.flushdb }

  it "claims a fingerprint, blocks a duplicate, and sets the TTL" do
    expect(store.claim("fp", ttl: 60)).to be_a(String)
    expect(store.claim("fp", ttl: 60)).to be(false)
    expect(redis.ttl("dedupe_test:dedup:fp")).to be > 0
  end

  it "normal release frees the fingerprint for re-claim (real Lua)" do
    token = store.claim("fp", ttl: 60)
    expect(store.release("fp", token)).to be_truthy
    expect(store.claim("fp", ttl: 60)).to be_a(String)
  end

  it "release deletes ONLY when the token matches (real Lua check-and-del)" do
    token = store.claim("fp", ttl: 60)

    # Simulate the race: the original key expired and a newer request re-claimed
    # it under a different token.
    redis.set("dedupe_test:dedup:fp", "newer-token")

    store.release("fp", token) # our (stale) token no longer matches → must be a no-op
    expect(redis.get("dedupe_test:dedup:fp")).to eq("newer-token")

    store.release("fp", "newer-token") # the real owner releases → key is deleted
    expect(redis.get("dedupe_test:dedup:fp")).to be_nil
  end
end
