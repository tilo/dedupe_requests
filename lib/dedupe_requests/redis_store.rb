# frozen_string_literal: true

require "securerandom"

module DedupeRequests
  # Redis-backed claim/release store.
  #
  # - claim:   atomic SET key <token> NX EX <ttl>. Returns the token on success,
  #            false if the key already exists (duplicate), or :error if Redis is
  #            unreachable (fail open).
  # - release: token-safe check-and-del via a Lua script — only deletes the key
  #            if it still holds OUR token, so a slow request whose TTL expired
  #            cannot wipe a newer request's fresh claim.
  class RedisStore
    RELEASE_SCRIPT = <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
      else
        return 0
      end
    LUA

    # Wraps a bare Redis client so it responds to #with like a connection pool,
    # giving one uniform access path regardless of what the user injected.
    class NullPool
      def initialize(redis)
        @redis = redis
      end

      def with
        yield @redis
      end
    end

    def initialize(redis_or_pool, namespace: "dedupe_requests", logger: nil)
      @pool = redis_or_pool.respond_to?(:with) ? redis_or_pool : NullPool.new(redis_or_pool)
      @namespace = namespace
      @logger = logger
    end

    def claim(fingerprint, ttl:)
      token = SecureRandom.hex(16)
      ok = @pool.with { |r| r.set(key(fingerprint), token, nx: true, ex: ttl) }
      ok ? token : false
    rescue StandardError => e
      log(e)
      :error
    end

    def release(fingerprint, token)
      @pool.with { |r| r.eval(RELEASE_SCRIPT, keys: [key(fingerprint)], argv: [token]) }
      true
    rescue StandardError => e
      log(e)
      false
    end

    def key(fingerprint)
      "#{@namespace}:dedup:#{fingerprint}"
    end

    private

    def log(error)
      @logger&.warn("[dedupe_requests] redis error: #{error.class}: #{error.message}")
    end
  end
end
