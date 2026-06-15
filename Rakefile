# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run the end-to-end HTTP integration test (boots a real Puma server; needs a running Redis)"
task :integration do
  script = File.expand_path("examples/end_to_end_test.rb", __dir__)
  sh RbConfig.ruby, script
end

task default: :spec
