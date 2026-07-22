require "json"
require "rack"
require "slim"
require "rollout"

require "rollout/ui/version"
require "rollout/ui/config"
require "rollout/ui/helpers"

module Rollout::UI
  class Web
    PUBLIC_PATH = File.expand_path('public', __dir__)

    NOT_FOUND = ->(env) { [404, { 'content-type' => 'text/plain' }, ['Not Found']] }

    def initialize
      @static = Rack::Static.new(NOT_FOUND, urls: ['/css'], root: PUBLIC_PATH)
    end

    def call(env)
      status, headers, body = @static.call(env)
      return [status, headers, body] unless status == 404

      Dispatcher.new.call(env)
    end

    # Handles a single request. A fresh instance is created per request (see
    # Web#call above) so the instance variables set by actions and read by
    # views (@rollout, @feature, etc) can't leak across concurrent requests.
    class Dispatcher
      include Helpers

      VIEWS_PATH = File.expand_path('views', __dir__)
      TEMPLATE_CACHE = {}

      ROUTES = [
        [:GET, %r{\A/\z}, :index],
        [:GET, %r{\A/features/new\z}, :new_feature],
        [:POST, %r{\A/features/new\z}, :create_feature],
        [:POST, %r{\A/features/(?<feature_name>[^/]+)/activate-percentage\z}, :activate_percentage],
        [:POST, %r{\A/features/(?<feature_name>[^/]+)/delete\z}, :delete_feature],
        [:GET, %r{\A/features/(?<feature_name>[^/]+)\z}, :show],
        [:POST, %r{\A/features/(?<feature_name>[^/]+)\z}, :update],
      ].freeze

      attr_reader :request, :response, :params

      def call(env)
        @request = Rack::Request.new(env)
        @response = Rack::Response.new

        route = ROUTES.find { |verb, pattern, _| verb == request.request_method.to_sym && pattern.match?(request.path_info) }
        return not_found unless route

        _, pattern, action = route
        @params = build_params(pattern.match(request.path_info).named_captures)

        send(action)
        response.finish
      end

      private

      def index
        @rollout = config.get(:instance)
        @features = @rollout.features.sort_by(&:downcase)
        if json_request?
          json(
            filtered_features(@rollout, @features).map do |feature|
              feature_to_hash(@rollout.get(feature))
            end
          )
        else
          render_view(:'features/index')
        end
      end

      def new_feature
        render_view(:'features/new')
      end

      def create_feature
        redirect_to feature_path(params[:name])
      end

      def show
        @rollout = config.get(:instance)
        @feature = @rollout.get(params[:feature_name])

        if json_request?
          json(feature_to_hash(@feature))
        else
          render_view(:'features/show')
        end
      end

      def update
        rollout = config.get(:instance)
        actor = config.get(:actor, scope: self)
        feature_data = rollout.get(params[:feature_name]).data
        if feature_data['updated_at'] && params[:last_updated_at].to_s != feature_data['updated_at'].to_s
          return redirect_to("#{feature_path(params[:feature_name])}?error=Rollout version outdated. Review changes below and try again.")
        end

        with_rollout_context(rollout, actor: actor) do
          rollout.with_feature(params[:feature_name]) do |feature|
            feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
            feature.groups = (params[:groups] || []).reject(&:empty?).map(&:to_sym)
            if params[:users]
              feature.users = params[:users].split(',').map(&:strip).uniq.sort
            end
            feature.data.update(description: params[:description])
            feature.data.update(updated_at: Time.now.to_i)
          end
        end

        redirect_to feature_path(params[:feature_name])
      end

      def activate_percentage
        rollout = config.get(:instance)
        actor = config.get(:actor, scope: self)

        with_rollout_context(rollout, actor: actor) do
          rollout.with_feature(params[:feature_name]) do |feature|
            feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
            feature.data.update(updated_at: Time.now.to_i)
          end
        end

        redirect_to index_path
      end

      def delete_feature
        @rollout = config.get(:instance)
        @rollout.delete(params[:feature_name])

        redirect_to index_path
      end

      def not_found
        response.status = 404
        response['content-type'] = 'text/plain'
        response.write('Not Found')
        response.finish
      end

      def build_params(route_params)
        request.params.merge(route_params).each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = value
          hash[key.to_sym] = value
        end
      end

      def redirect_to(location)
        response.redirect(location)
      end

      def json(data)
        response['content-type'] = 'application/json'
        response.write(data.to_json)
      end

      def render_view(name)
        response['content-type'] = 'text/html;charset=utf-8'
        response.write(render_template(:layout) { render_template(name) })
      end

      # Called from within views to render a partial, e.g.
      # `== slim :"features/partials/event_log", locals: { events: events }`
      def slim(name, locals: {})
        render_template(name, locals)
      end

      def render_template(name, locals = {}, &block)
        template = (TEMPLATE_CACHE[name] ||= Slim::Template.new(File.join(VIEWS_PATH, "#{name}.slim")))
        template.render(self, locals, &block)
      end
    end
  end
end
