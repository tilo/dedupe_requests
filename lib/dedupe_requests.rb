# frozen_string_literal: true

require "dedupe_requests/version"
require "dedupe_requests/fingerprint"
require "dedupe_requests/redis_store"
require "dedupe_requests/configuration"
require "dedupe_requests/guard"

module DedupeRequests
  class Error < StandardError; end

  # The only verbs ever guarded. GET and DELETE are deliberately never deduped.
  MUTATING_VERBS = %w[POST PUT PATCH].freeze

  class << self
    def config
      @config ||= Configuration.new
    end
    alias configuration config

    def configure
      yield config
      config
    end

    def reset_configuration!
      @config = Configuration.new
    end
  end
end

# The controller concern needs ActiveSupport (a runtime dependency).
require "dedupe_requests/controller"
