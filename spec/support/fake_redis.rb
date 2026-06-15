# frozen_string_literal: true

# A minimal in-memory stand-in for a Redis client, implementing exactly the
# commands RedisStore uses: SET (with NX/EX), GET, DEL, and EVAL.
#
# `eval` faithfully implements the single Lua script we use (token-safe
# check-and-del), so it exercises the same release semantics as real Redis.
class FakeRedis
  def initialize
    @store = {}
  end

  def set(key, value, nx: false, ex: nil) # rubocop:disable Lint/UnusedMethodArgument
    return false if nx && @store.key?(key)

    @store[key] = value
    true
  end

  def get(key)
    @store[key]
  end

  def del(*keys)
    keys.sum { |k| @store.delete(k) ? 1 : 0 }
  end

  # Implements RedisStore::RELEASE_SCRIPT: delete only if the stored value
  # matches our token.
  def eval(_script, keys:, argv:)
    key = keys.first
    token = argv.first
    if @store[key] == token
      @store.delete(key)
      1
    else
      0
    end
  end
end
