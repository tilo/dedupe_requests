# frozen_string_literal: true

module DedupeRequests
  # Framework-agnostic core: turns a request into a claim decision, and releases
  # a claim. Knows nothing about Rails rendering — that lives in the concern.
  class Guard
    # outcome: :claimed | :duplicate | :skip
    Result = Struct.new(:outcome, :fingerprint, :token)

    def initialize(config)
      @config = config
    end

    def claim(request, ttl: @config.ttl, caller_id: nil)
      return Result.new(:skip) unless @config.enabled?
      return Result.new(:skip) unless DedupeRequests::MUTATING_VERBS.include?(request.request_method.to_s)

      store = @config.store
      return Result.new(:skip) unless store

      fingerprint = Fingerprint.for_request(request, @config, caller_id: caller_id)
      token = store.claim(fingerprint, ttl: ttl)

      case token
      when :error then Result.new(:skip) # Redis down → fail open
      when false  then Result.new(:duplicate, fingerprint)
      else             Result.new(:claimed, fingerprint, token)
      end
    end

    def release(result)
      return false unless result && result.outcome == :claimed

      @config.store.release(result.fingerprint, result.token)
    end
  end
end
