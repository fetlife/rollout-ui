# Development Rackup config you can run with `bundle exec rerun rackup`

require_relative 'lib/rollout/ui'
require 'redis'
require "rack/protection"
use Rack::Session::Cookie,
  key: 'rack.session',
  path: '/',
  secret: ENV.fetch('SECRET_KEY_BASE', '2cf276c70e0b98b8776b1ef584a79591224e38275b6943c0e02ba8039ba25b69ff2aff8cb003e782963c3563e68e46934d3403e6b885e6b9b2324eaa6331e0c5')
use Rack::Protection::AuthenticityToken

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
