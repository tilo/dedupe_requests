# frozen_string_literal: true

require "digest"

module DedupeRequests
  # Computes a stable fingerprint for a request.
  #
  # The fingerprint covers: caller_id + verb + path + query string + body.
  # Time is NOT part of the fingerprint — the dedup window is the Redis TTL.
  module Fingerprint
    ALGORITHMS = {
      sha256: ->(data) { Digest::SHA256.hexdigest(data) },
      sha1:   ->(data) { Digest::SHA1.hexdigest(data) },
      sha512: ->(data) { Digest::SHA512.hexdigest(data) },
      md5:    ->(data) { Digest::MD5.hexdigest(data) }
    }.freeze

    module_function

    def for_request(request, config)
      return config.fingerprint.call(request) if config.fingerprint

      parts = [
        caller_id(request, config).to_s,
        request.request_method.to_s,
        request.path.to_s,
        request.query_string.to_s,
        body(request, config)
      ]
      digest(parts, config.digest)
    end

    # Length-prefixes each field so a value cannot "shift" across a field
    # boundary and collide with a different set of fields.
    def digest(parts, algorithm = :sha256)
      data = Array(parts).map { |part| s = part.to_s; "#{s.bytesize}:#{s}" }.join
      resolve(algorithm).call(data)
    end

    def resolve(algorithm)
      return algorithm if algorithm.respond_to?(:call)

      ALGORITHMS.fetch(algorithm.to_sym) do
        raise ArgumentError, "unknown digest #{algorithm.inspect} (known: #{ALGORITHMS.keys.join(', ')} or a callable)"
      end
    end

    def caller_id(request, config)
      config.caller_id ? config.caller_id.call(request) : nil
    end

    def body(request, config)
      raw = (request.respond_to?(:raw_post) ? request.raw_post : read_and_rewind(request)).to_s
      cap = config.max_body_bytes
      cap ? raw.byteslice(0, cap).to_s : raw
    end

    def read_and_rewind(request)
      return "" unless request.respond_to?(:body) && request.body
      data = request.body.read
      request.body.rewind if request.body.respond_to?(:rewind)
      data
    end
  end
end
