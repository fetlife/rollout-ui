require "bundler/setup"
require "rollout/ui"
require 'rack/test'
require 'pry'
require 'redis'

REDIS = Redis.new
ROLLOUT = Rollout.new(REDIS)
Rollout::UI.configure do
  instance { ROLLOUT }
end
RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
