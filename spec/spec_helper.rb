require "bundler/setup"
require "rollout/ui"
require "rollout/adapters/redis"
require "rack/test"
require "pry"
require "redis"

REDIS = Redis.new
ROLLOUT = Rollout.new(
  adapter: Rollout::Adapters::Redis.new(REDIS),
  logging: { history_length: 100, global: true },
)

%i[employees developers subscribers].each do |group|
  ROLLOUT.define_group(group) { }
end

Rollout::UI.configure do
  instance { ROLLOUT }
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
