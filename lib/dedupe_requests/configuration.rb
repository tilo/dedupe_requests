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

    # Per-caller identity. The callable is given the CONTROLLER, so it can read
    # anything the controller exposes — `current_user`, a helper method, or a
    # header via `controller.request`. Examples:
    #   c.caller_id = ->(controller) { controller.current_user&.id }
    #   c.caller_id = ->(controller) { controller.request.get_header("HTTP_X_API_KEY") }
    #
    # The default derives identity from the request's Authorization header,
    # falling back to a Rails-style session cookie (so token- and cookie-auth
    # apps work with no configuration). It accepts either a controller or a bare
    # request.
    DEFAULT_CALLER_ID = lambda do |context|
      request = context.respond_to?(:request) ? context.request : context
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
      @caller_id = DEFAULT_CALLER_ID
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
