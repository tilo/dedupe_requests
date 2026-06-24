# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/class/attribute"

module DedupeRequests
  # Rails controller integration.
  #
  #   class ApplicationController < ActionController::Base
  #     include DedupeRequests::Controller
  #     dedupe_requests on: %i[create update]
  #   end
  #
  # Registers a SINGLE around_action that, for each guarded action, claims before
  # the action runs and releases on a 4xx/5xx response or a raised exception
  # (2xx/3xx keep the claim). The guarded actions and their per-action TTLs live
  # in an inherited class_attribute map, so subclasses extend or trim it.
  module Controller
    extend ActiveSupport::Concern

    included do
      # Map of guarded action (Symbol) => TTL (Integer, or nil meaning "use the
      # global config TTL"). Inherited and copy-on-write, so a subclass can add
      # to or trim it without touching the parent.
      class_attribute :dedupe_requests_action_ttls, instance_accessor: false, default: {}
      around_action :dedupe_requests_around
    end

    class_methods do
      # Guard the named actions. A `ttl:`, if given, applies to exactly the
      # actions named in THIS call. Calls accumulate, so per-action TTLs are
      # expressed by repeating the line:
      #
      #   dedupe_requests on: %i[create update]       # both, global TTL
      #   dedupe_requests on: [:create], ttl: 120     # create → 120
      #   dedupe_requests on: [:update], ttl: 180     # update → 180
      #
      # Re-naming an action overrides its TTL. Subclasses inherit the map and can
      # add to it or remove from it (`skip:` / `skip_dedupe_requests`).
      def dedupe_requests(on: nil, skip: nil, ttl: nil)
        map = dedupe_requests_action_ttls.dup

        Array(on).each { |action| map[action.to_sym] = ttl }
        Array(skip).each { |action| map.delete(action.to_sym) }

        self.dedupe_requests_action_ttls = map
      end

      def skip_dedupe_requests(on: nil)
        map = dedupe_requests_action_ttls.dup
        Array(on).each { |action| map.delete(action.to_sym) }
        self.dedupe_requests_action_ttls = map
      end

      # The set of guarded actions (the keys of the TTL map).
      def dedupe_requests_actions
        dedupe_requests_action_ttls.keys
      end
    end

    private

    def dedupe_requests_around
      unless dedupe_requests_applies?
        yield
        return
      end

      # GET/DELETE are never deduped — bail out before resolving caller_id, so the
      # caller_id callable only runs for the verbs we actually de-duplicate.
      unless dedupe_requests_mutating_verb?
        yield
        return
      end

      caller_id = dedupe_requests_caller_id
      # Without a caller identity, every unidentified caller would share one
      # fingerprint, so two genuinely-different requests with the same body would
      # collide and the second would be wrongly rejected. Skip de-duplication in
      # that case (let the request through) and warn, rather than risk a false 409.
      if caller_id.nil?
        dedupe_requests_warn_missing_caller_id
        yield
        return
      end

      result = dedupe_requests_guard.claim(
        request,
        ttl: dedupe_requests_ttl_for(action_name),
        caller_id: caller_id
      )

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

      self.class.dedupe_requests_action_ttls.key?(action_name.to_sym)
    end

    # Per-action TTL, falling back to the global config TTL.
    def dedupe_requests_ttl_for(action)
      self.class.dedupe_requests_action_ttls[action.to_sym] || DedupeRequests.config.ttl
    end

    # Resolve the caller identity by handing the whole controller to the
    # configured `caller_id` callable (so it can use current_user, a header, etc.).
    def dedupe_requests_caller_id
      DedupeRequests.config.caller_id&.call(self)
    end

    def dedupe_requests_mutating_verb?
      DedupeRequests::MUTATING_VERBS.include?(request.request_method.to_s)
    end

    # Loud on purpose: a missing caller identity silently weakens de-duplication,
    # so we warn on every such request (via the configured logger, else stderr).
    def dedupe_requests_warn_missing_caller_id
      message = "[dedupe_requests] caller_id resolved to nil for #{controller_name}##{action_name} (#{request.request_method} #{request.path}); de-duplication skipped. Configure DedupeRequests.config.caller_id."
      logger = DedupeRequests.config.logger
      logger ? logger.warn(message) : warn(message)
    end

    def dedupe_requests_guard
      @dedupe_requests_guard ||= DedupeRequests::Guard.new(DedupeRequests.config)
    end

    # Keep the fingerprint when the request was handled — a 2xx, or a 3xx
    # redirect (the Post/Redirect/Get pattern is a *successful* create) — so a
    # later duplicate is still blocked for the full TTL. Only a 4xx/5xx (or a
    # raised exception) releases it, so a genuinely failed request can be retried.
    def dedupe_requests_release?(status)
      status.to_i >= 400
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
