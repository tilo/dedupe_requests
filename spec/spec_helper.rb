# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
  minimum_coverage line: 100, branch: 100
end

require "dedupe_requests"
require_relative "support/fake_redis"
require_relative "support/request_double"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec)
  config.before { DedupeRequests.reset_configuration! }
end
