require "sinatra"
require "rollout"

require "rollout/ui/version"
require "rollout/ui/config"
require "rollout/ui/web"

class Rollout
  module UI
    def self.configure(&block)
      @config ||= Config.new
      @config.instance_eval &block
    end

    def self.config
      @config
    end
  end
end
