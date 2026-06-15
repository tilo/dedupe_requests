# frozen_string_literal: true

require "digest"

begin
  require "openssl"
rescue LoadError
  # Ruby built without OpenSSL — the digests fall back to the stdlib Digest below.
end

module DedupeRequests
  # Computes a stable fingerprint for a request.
  #
  # The fingerprint covers: caller_id + verb + path + query string + body.
  # Time is NOT part of the fingerprint — the dedup window is the Redis TTL.
  module Fingerprint
    # Prefer OpenSSL (uses the CPU's SHA instructions — several times faster on
    # large bodies), falling back to the stdlib Digest when OpenSSL is unavailable
    # or has the algorithm disabled (e.g. MD5 under FIPS). Output is identical.
    HASHERS = {
      sha256: ["SHA256", Digest::SHA256],
      sha1: ["SHA1", Digest::SHA1],
      sha512: ["SHA512", Digest::SHA512],
      md5: ["MD5", Digest::MD5]
    }.freeze

    ALGORITHMS = HASHERS.transform_values do |(openssl_name, digest_class)|
      lambda do |data|
        OpenSSL::Digest.hexdigest(openssl_name, data)
      rescue StandardError
        digest_class.hexdigest(data)
      end
    end.freeze

    module_function

    def for_request(request, config, caller_id: nil)
      return config.fingerprint.call(request) if config.fingerprint

      parts = [
        caller_id.to_s,
        request.request_method.to_s,
        request.path.to_s,
        request.query_string.to_s,
        body(request)
      ]
      digest(parts, config.digest)
    end

    # Length-prefixes each field so a value cannot "shift" across a field
    # boundary and collide with a different set of fields.
    def digest(parts, algorithm = :sha256)
      data = Array(parts).map do |part|
        s = part.to_s
        "#{s.bytesize}:#{s}"
      end.join
      resolve(algorithm).call(data)
    end

    def resolve(algorithm)
      return algorithm if algorithm.respond_to?(:call)

      ALGORITHMS.fetch(algorithm.to_sym) do
        raise ArgumentError, "unknown digest #{algorithm.inspect} (known: #{ALGORITHMS.keys.join(', ')} or a callable)"
      end
    end

    def body(request)
      request.respond_to?(:raw_post) ? request.raw_post.to_s : read_and_rewind(request).to_s
    end

    def read_and_rewind(request)
      return "" unless request.respond_to?(:body) && request.body

      data = request.body.read
      request.body.rewind if request.body.respond_to?(:rewind)
      data
    end
  end
end
