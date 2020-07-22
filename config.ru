# Development Rackup config you can run with `bundle exec rerun rackup`

require_relative 'lib/rollout/ui'
require 'redis'

redis_host = ENV.fetch('REDIS_HOST', 'localhost')
redis_port = ENV.fetch('REDIS_PORT', '6379')
redis_db = ENV.fetch('REDIS_DB', '10')

redis = Redis.new(host: redis_host, port: redis_port, db: redis_db)
rollout = Rollout.new(redis, logging: { history_length: 100, global: true })

%i[employees developers subscribers].each do |group|
  rollout.define_group(group) { }
end

Rollout::UI.configure do
  instance { rollout }
  actor { "JohnDoe" }
  actor_url { "https://www.youtube.com/watch?v=fbGkxcY7YFU" }
end

run Rollout::UI::Web.new
