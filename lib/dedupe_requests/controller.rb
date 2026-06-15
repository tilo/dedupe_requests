# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/class/attribute"

module DedupeRequests
  # Rails controller integration.
  #
  #   class ApplicationController < ActionController::Base
  #     include DedupeRequests::Controller
  #     dedupe_requests only: %i[create update]
  #   end
  #
  # Registers a SINGLE around_action that, for actions in the controller's
  # de-dupe set, claims before the action runs and releases on any non-2xx
  # response or raised exception. The set is an inherited class_attribute so
  # subclasses can replace (only:), extend (also:), or trim (skip:) it.
  module Controller
    extend ActiveSupport::Concern

    included do
      class_attribute :dedupe_requests_actions, instance_accessor: false, default: nil
      class_attribute :dedupe_requests_options, instance_accessor: false, default: {}
      around_action :dedupe_requests_around
    end

    class_methods do
      def dedupe_requests(only: nil, also: nil, skip: nil, **options)
        inherited = dedupe_requests_actions || []
        new_set =
          if only
            Array(only).map(&:to_sym)
          else
            set = inherited.dup
            set |= Array(also).map(&:to_sym) if also
            set -= Array(skip).map(&:to_sym) if skip
            set
          end
        self.dedupe_requests_actions = new_set.uniq
        self.dedupe_requests_options = dedupe_requests_options.merge(options) unless options.empty?
      end

      def skip_dedupe_requests(only: nil)
        self.dedupe_requests_actions = (dedupe_requests_actions || []) - Array(only).map(&:to_sym)
      end
    end

    private

    def dedupe_requests_around
      unless dedupe_requests_applies?
        yield
        return
      end

      ttl = self.class.dedupe_requests_options[:ttl] || DedupeRequests.config.ttl
      result = dedupe_requests_guard.claim(request, ttl: ttl)

      case result.outcome
      when :duplicate
        dedupe_requests_notify(:on_duplicate_detected, result)
        if DedupeRequests.config.mode == :enforce
          dedupe_requests_notify(:on_duplicate_rejected, result)
          dedupe_requests_render_conflict
        else
          yield # observe mode: detected but allowed through
        end
      when :claimed
        begin
          yield
        rescue Exception # rubocop:disable Lint/RescueException
          dedupe_requests_guard.release(result)
          raise
        else
          dedupe_requests_guard.release(result) if dedupe_requests_release?(response.status)
        end
      else # :skip
        yield
      end
    end

    def dedupe_requests_applies?
      return false unless DedupeRequests.config.enabled?

      actions = self.class.dedupe_requests_actions
      !actions.nil? && actions.include?(action_name.to_sym)
    end

    def dedupe_requests_guard
      @dedupe_requests_guard ||= DedupeRequests::Guard.new(DedupeRequests.config)
    end

    # A request didn't complete successfully → free the fingerprint so a genuine
    # retry isn't blocked. Only a 2xx keeps the fingerprint for the full TTL.
    def dedupe_requests_release?(status)
      code = status.to_i
      code < 200 || code >= 300
    end

    def dedupe_requests_render_conflict
      response.set_header("X-Dedupe-Request", "true")
      render json: DedupeRequests.config.conflict_body, status: DedupeRequests.config.conflict_status
    end

    def dedupe_requests_notify(hook, result)
      callback = DedupeRequests.config.public_send(hook)
      return unless callback

      callback.call(
        fingerprint: result.fingerprint,
        controller: controller_name,
        action: action_name,
        verb: request.request_method,
        path: request.path
      )
    end
  end
end
