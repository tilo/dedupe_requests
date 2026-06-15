# frozen_string_literal: true

require_relative "lib/dedupe_requests/version"

Gem::Specification.new do |spec|
  spec.name     = "dedupe_requests"
  spec.version  = DedupeRequests::VERSION
  spec.authors  = ["Tilo Sloboda"]
  spec.email    = ["tilo.sloboda@gmail.com"]

  spec.summary  = "Automatic server-side de-duplication of inbound mutating Rails requests (POST/PUT/PATCH) via a payload fingerprint and Redis."
  spec.description = "Detects and rejects duplicate inbound POST/PUT/PATCH requests with a 409/conflict, with no client-side idempotency key required. The server auto-computes a fingerprint of each mutating request, claims it atomically in Redis, and short-circuits duplicates seen within a configurable time window, so they don't overwhelm your server or cause 5xx errors."
  spec.homepage = "https://github.com/tilo/dedupe_requests"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 2.6"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
