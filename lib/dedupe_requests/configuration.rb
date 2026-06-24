# frozen_string_literal: true

module DedupeRequests
  class Configuration
    MODES = %i[off observe enforce].freeze

    DEFAULT_CONFLICT_BODY = {
      "errors" => [{
        "error_key" => "base",
        "category" => "duplicate_operation",
        "message" => "Duplicate request detected. A matching request is in-flight or recently completed."
      }]
    }.freeze

    # Per-caller identity. There is NO default — you MUST configure `caller_id`
    # with a callable that returns a stable, non-secret identifier for the caller
    # (a user id, a JWT `sub`, an API-client id). Do NOT use a raw bearer token or
    # API key: it's secret and it rotates, so the same caller would look like
    # different callers and de-duplication would silently weaken. The callable is
    # given the CONTROLLER, so it can read `current_user`, a helper, or a header via
    # `controller.request`. Examples:
    #   c.caller_id = ->(controller) { controller.current_user&.id }
    #   c.caller_id = ->(controller) { controller.request.get_header("HTTP_X_API_KEY") }
    # When `caller_id` is unset or returns nil, de-duplication is skipped for the
    # request (and a warning is logged), rather than risk treating different callers
    # as one.
    attr_accessor :redis, :ttl, :digest, :namespace, :caller_id, :fingerprint,
                  :conflict_status, :logger,
                  :on_duplicate_detected, :on_duplicate_rejected
    attr_writer :store, :conflict_body
    attr_reader :mode

    def initialize
      @redis = nil
      @store = nil
      @mode = :enforce
      @ttl = 90
      @digest = :sha256
      @namespace = "dedupe_requests"
      @caller_id = nil
      @fingerprint = nil
      @conflict_status = 409
      @logger = nil
      @on_duplicate_detected = nil
      @on_duplicate_rejected = nil
      @conflict_body = nil
    end

    def mode=(value)
      sym = value.to_sym
      unless MODES.include?(sym)
        raise ArgumentError, "unknown mode #{value.inspect} (expected one of #{MODES.join(', ')})"
      end

      @mode = sym
    end

    def enabled?
      @mode != :off
    end

    def store
      @store ||= (RedisStore.new(@redis, namespace: @namespace, logger: @logger) if @redis)
    end

    def conflict_body
      @conflict_body || DEFAULT_CONFLICT_BODY
    end
  end
end
