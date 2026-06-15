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

    # Default per-caller identity: the Authorization header, falling back to a
    # Rails-style session cookie. Override via `config.caller_id`.
    DEFAULT_CALLER_ID = lambda do |request|
      if request.respond_to?(:get_header)
        auth = request.get_header("HTTP_AUTHORIZATION")
        return auth if auth && !auth.to_s.empty?
      end
      if request.respond_to?(:cookies)
        request.cookies.each { |name, value| return value if name.to_s =~ /\A_.*_session\z/i }
      end
      nil
    end

    attr_accessor :redis, :ttl, :digest, :namespace, :caller_id, :fingerprint,
                  :max_body_bytes, :conflict_status, :logger,
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
      @caller_id = DEFAULT_CALLER_ID
      @fingerprint = nil
      @max_body_bytes = nil
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
