require "bundler/setup"
require "rollout/ui"
require "rollout/redis"
require "rack/test"
require "pry"
require "redis"

REDIS = ::Redis.new(
  host: ENV.fetch("REDIS_HOST", "127.0.0.1"),
  port: ENV.fetch("REDIS_PORT", "6379"),
  db: ENV.fetch("REDIS_DB", "7"),
)
ROLLOUT = Rollout.new(
  backend: Rollout::Redis::Backend.new(REDIS),
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

  config.before do
    REDIS.flushdb
  end
end
