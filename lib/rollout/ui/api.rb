# frozen_string_literal: true

require 'json'
require 'uri'
require 'time'
require 'date'
require 'rollout'

class Rollout
  module UI
    # Mount explicitly behind the host's authentication and read authorization.
    class API
      MAX_BYTES = 1_048_576
      MAX_QUERY_BYTES = 1024

      class Failure < StandardError
        attr_reader :status, :code

        def initialize(status, code)
          @status, @code = status, code
        end
      end

      def initialize(instance:, environment:)
        unless environment.is_a?(String) && !environment.empty? && environment.bytesize <= 256 && environment.valid_encoding?
          raise ArgumentError, 'environment must be a nonempty string of at most 256 bytes'
        end
        @rollout, @environment = instance, environment.dup.freeze
      end

      def call(env)
        fail_request(405, 'method_not_allowed') unless env['REQUEST_METHOD'] == 'GET'
        path = env.fetch('PATH_INFO', '')
        fail_request(400, 'invalid_name') if path.bytesize > 1024
        case path
        when '/features'
          query = parse_query(env, ['limit'])
          limit = parse_limit(query)
          names = @rollout.features.map(&:to_s).sort_by(&:b)
          features = names.first(limit).map { |name| feature(name) }
          respond(200, features: features, meta: { limit: limit, truncated: names.length > limit })
        when '/history'
          history(nil, parse_query(env, ['limit', 'since']))
        when %r{\A/features/([^/]+)(/history)?\z}
          name = decode_name(Regexp.last_match(1))
          history_route = Regexp.last_match(2)
          query = parse_query(env, history_route ? ['limit', 'since'] : [])
          exists!(name)
          history_route ? history(name, query) : respond(200, feature: feature(name))
        else
          fail_request(404, 'route_not_found')
        end
      rescue Failure => error
        headers = error.status == 405 ? { 'allow' => 'GET' } : {}
        respond(error.status, { error: { code: error.code, message: error.code.tr('_', ' ') } }, headers)
      rescue NotImplementedError
        respond(503, error: { code: 'history_unavailable', message: 'History backend unavailable' })
      rescue StandardError
        respond(503, error: { code: 'service_unavailable', message: 'Rollout service unavailable' })
      end

      private

      def fail_request(status, code)
        raise Failure.new(status, code)
      end

      def parse_query(env, allowed)
        raw = env.fetch('QUERY_STRING', '')
        fail_request(400, 'invalid_query') if raw.bytesize > MAX_QUERY_BYTES || raw.match?(/%(?![0-9a-fA-F]{2})/)
        pairs = URI.decode_www_form(raw, Encoding::UTF_8)
        keys = pairs.map(&:first)
        fail_request(400, 'invalid_query') unless (keys - allowed).empty? && keys.uniq == keys
        pairs.to_h
      rescue ArgumentError
        fail_request(400, 'invalid_query')
      end

      def parse_limit(query)
        value = query.fetch('limit', '100')
        fail_request(400, 'invalid_limit') unless value.match?(/\A[0-9]{1,4}\z/) && (1..1000).cover?(value.to_i)
        value.to_i
      end

      def parse_since(value)
        return nil unless value
        fail_request(400, 'invalid_since') unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
        Date.iso8601(value[0, 10])
        DateTime.rfc3339(value)
        Time.iso8601(value).utc
      rescue ArgumentError
        fail_request(400, 'invalid_since')
      end

      def decode_name(segment)
        fail_request(400, 'invalid_name') if segment.match?(/%(?![0-9a-fA-F]{2})/)
        name = URI::DEFAULT_PARSER.unescape(segment).force_encoding(Encoding::UTF_8)
        unless name.valid_encoding? && (1..256).cover?(name.bytesize) && !name.match?(/[[:cntrl:]]/)
          fail_request(400, 'invalid_name')
        end
        name
      end

      def exists!(name)
        fail_request(404, 'feature_not_found') unless @rollout.adapter.feature_exists?(name)
      end

      def feature(name)
        exists!(name)
        state = @rollout.get(name)
        # A concurrent deletion must not turn a read into synthetic inactive state.
        fail_request(503, 'feature_changed') unless @rollout.adapter.feature_exists?(name)
        {
          name: name, percentage: state.percentage,
          groups: state.groups.map(&:to_s).sort_by(&:b),
          users: state.users.map(&:to_s).sort_by(&:b), data: state.data
        }
      end

      def history(name, query)
        limit = parse_limit(query)
        since = parse_since(query['since'])
        logger = @rollout.respond_to?(:logging) ? @rollout.logging : nil
        enabled = !!(logger && logger.logging_enabled? && (name || logger.global))
        events = if enabled
          name ? logger.events(name, limit: limit + 1) : logger.global_events(limit: limit + 1)
        else
          []
        end
        events = events.reverse.select { |event| !since || event.created_at >= since }
        respond(200, events: events.first(limit).map { |event| serialize_event(event) }, meta: {
          limit: limit, truncated: events.length > limit, scope: name ? 'feature' : 'global',
          feature: name, since: since && since.iso8601(6), retention: {
            enabled: enabled, max_events: logger && logger.history_length,
            oldest_available_at: nil, completeness: 'unknown', deletion_events: false
          }
        })
      end

      def serialize_event(event)
        {
          feature: event.feature.to_s, name: event.name.to_s, data: event.data,
          context: event.context, created_at: event.created_at.utc.iso8601(6)
        }
      end

      def respond(status, payload, headers = {})
        body = JSON.generate({ api_version: 1, environment: @environment }.merge(payload))
        if body.bytesize > MAX_BYTES
          return respond(413, error: { code: 'response_too_large', message: 'Response exceeds 1 MiB' })
        end
        [status, { 'content-type' => 'application/json', 'cache-control' => 'no-store',
                   'content-length' => body.bytesize.to_s }.merge(headers), [body]]
      end
    end
  end
end
