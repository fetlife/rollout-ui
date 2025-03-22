require "sinatra"
require "rollout"

require "rollout/ui/version"

module Rollout::UI
  class Config
    KEYS = %i[
      instance
      actor
      actor_url
      timestamp_format
    ].freeze

    DEFAULT_VALUES = {
      timestamp_format: '%Y-%m-%d %H:%M %Z'
    }.freeze

    KEYS.each do |key|
      define_method(key) do |&block|
        @blocks ||= {}

        if block
          @blocks[key] = block
        elsif DEFAULT_VALUES.key?(key)
          DEFAULT_VALUES[key]
        else
          raise ArgumentError, "#{key}: block is required"
        end
      end
    end

    def get(key, *args, scope: nil)
      raise ArgumentError, "Invalid config key: #{key}" unless KEYS.include?(key)

      @blocks ||= {}
      block = @blocks[key]

      if block.nil?
        return DEFAULT_VALUES[key] if DEFAULT_VALUES.key?(key)
        return nil
      end

      if scope
        scope.instance_eval(&block)
      else
        block.call(*args)
      end
    end

    def defined?(key)
      (@blocks&.key?(key)) || DEFAULT_VALUES.key?(key)
    end
  end
end
