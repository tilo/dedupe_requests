# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

desc "Run the end-to-end HTTP integration test (boots a real Puma server; needs a running Redis)"
task :integration do
  script = File.expand_path("examples/end_to_end_test.rb", __dir__)
  sh RbConfig.ruby, script
end

task default: :spec
