require "erb"
require "json"
require "rack"
require "rollout"

require "rollout/ui/version"
require "rollout/ui/config"
require "rollout/ui/helpers"

module Rollout::UI
  class Web
    PUBLIC_PATH = File.expand_path('public', __dir__)

    NOT_FOUND = ->(env) { [404, { 'content-type' => 'text/plain', 'x-cascade' => 'pass' }, ['Not Found']] }

    def initialize
      @static = Rack::Static.new(NOT_FOUND, urls: ['/css', '/js'], root: PUBLIC_PATH)
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

      class StaleFeature < StandardError
      end

      class InvalidEnrollment < StandardError
      end

      STALE_FEATURE_MESSAGE = 'This rollout changed since you opened it. Your update was not saved. Review the latest state and try again.'

      VIEWS_PATH = File.expand_path('views', __dir__)
      TEMPLATE_CACHE = {}
      HISTORY_USER_LOOKUP_LIMIT = 150

      ROUTES = [
        [:GET, %r{\A/\z}, :index],
        [:GET, %r{\A/users/search\z}, :search_users],
        [:GET, %r{\A/features/(?<feature_name>[^/]+)/users/search\z}, :search_feature_users],
        [:GET, %r{\A/features/(?<feature_name>[^/]+)/users\z}, :enrolled_users],
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
        response['x-content-type-options'] = 'nosniff'
        response['x-frame-options'] = 'SAMEORIGIN'
        response['x-xss-protection'] = '1; mode=block'

        # Rack::URLMap strips the mount prefix from PATH_INFO, leaving "" (not
        # "/") when a mounted app is requested at its exact mount point.
        path_info = request.path_info
        path_info = '/' if path_info.empty?

        method = request.request_method.to_sym
        lookup_method = method == :HEAD ? :GET : method
        route = ROUTES.find { |verb, pattern, _| verb == lookup_method && pattern.match?(path_info) }
        return not_found unless route

        _, pattern, action = route
        begin
          @params = build_params(pattern.match(path_info).named_captures)
        rescue Rack::BadRequest => e
          return bad_request(e)
        end

        send(action)
        response.body = [] if method == :HEAD
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
          @history_events = @rollout.respond_to?(:logging) ? @rollout.logging.global_events.reverse : []
          load_history_user_nicknames(@history_events)
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
        response['cache-control'] = 'no-store'
        @rollout = config.get(:instance)
        @feature = @rollout.get(params[:feature_name])

        if json_request?
          json(feature_to_hash(@feature))
        else
          load_selected_users
          @history_events = @rollout.respond_to?(:logging) ? @rollout.logging.events(@feature.name).reverse : []
          load_history_user_nicknames(@history_events)
          render_view(:'features/show')
        end
      end

      def search_users
        return not_found unless user_selector_enabled?

        response['cache-control'] = 'no-store'
        query = params[:q]
        unless query.nil? || query.is_a?(String)
          response.status = 400
          return json(error: 'Nickname must be a string.')
        end
        query = query.to_s.strip
        if query.length > USER_SEARCH_MAX_LENGTH
          response.status = 400
          return json(error: "Nickname must be at most #{USER_SEARCH_MAX_LENGTH} characters.")
        end
        return json(users: []) if query.length < user_search_min_length

        begin
          users = config.get(:user_search, query, user_search_limit)
          json(users: users.take(user_search_limit).map { |user| user_to_hash(user) })
        rescue StandardError
          response.status = 503
          json(error: 'Nickname search is temporarily unavailable. Please try again.')
        end
      end

      def search_feature_users
        return not_found unless user_selector_enabled?

        response['cache-control'] = 'no-store'
        @rollout = config.get(:instance)
        begin
          @feature = @rollout.get(params[:feature_name])
        rescue StandardError
          return not_found
        end

        query = params[:q]
        unless query.nil? || query.is_a?(String)
          response.status = 400
          return json(error: 'Nickname must be a string.')
        end
        query = query.to_s.strip
        if query.length > USER_SEARCH_MAX_LENGTH
          response.status = 400
          return json(error: "Nickname must be at most #{USER_SEARCH_MAX_LENGTH} characters.")
        end
        return json(users: [], feature_version: feature_version(@feature)) if query.length < user_search_min_length

        enrolled_ids = @feature.users.map(&:to_s)
        begin
          users = config.get(:user_search, query, user_search_limit)
          json(
            users: users.take(user_search_limit).map do |user|
              hashed = user_to_hash(user)
              hashed.merge(enrolled: enrolled_ids.include?(hashed[:id]))
            end,
            feature_version: feature_version(@feature),
          )
        rescue StandardError
          response.status = 503
          json(error: 'Nickname search is temporarily unavailable. Please try again.')
        end
      end

      def enrolled_users
        response['cache-control'] = 'no-store'
        @rollout ||= config.get(:instance)
        begin
          @feature = @rollout.get(params[:feature_name])
        rescue StandardError
          return not_found
        end
        load_selected_users

        json(
          users: @selected_users,
          total: @users_total_count,
          page: @user_page,
          per_page: @users_per_page,
          total_pages: @users_total_pages,
          feature_version: feature_version(@feature),
          lookup_failed: @selected_user_lookup_failed || false,
        )
      end

      def load_selected_users
        @users_per_page = parse_users_per_page(params[:per_page])
        all_ids = @feature.users.map { |id| id.to_s }.uniq.sort
        @users_total_count = all_ids.size
        @users_total_pages = [ (all_ids.size.to_f / @users_per_page).ceil, 1 ].max
        @user_page = parse_users_page(params[:page], @users_total_pages)
        offset = (@user_page - 1) * @users_per_page
        page_ids = all_ids[offset, @users_per_page] || []
        if config.defined?(:user_lookup)
          lookup_user_nicknames(page_ids)
        end
        @selected_users = page_ids.map { |id| { id: id, nickname: user_label(id) } }
        @selected_user_lookup_failed = @user_lookup_failed == true
      end

      def parse_users_per_page(value)
        return USER_PAGE_SIZE if value.is_a?(Array) || value.is_a?(Hash)
        raw = value.to_s.strip
        return USER_PAGE_SIZE unless raw.match?(/\A\d+\z/)
        candidate = raw.to_i
        USER_PAGE_SIZES.include?(candidate) ? candidate : USER_PAGE_SIZE
      end

      def parse_users_page(value, total_pages)
        candidate = 1
        unless value.is_a?(Array) || value.is_a?(Hash)
          raw = value.to_s.strip
          candidate = raw.to_i if raw.match?(/\A\d+\z/)
        end
        candidate = 1 if candidate < 1
        candidate = total_pages if candidate > total_pages
        candidate = 1 if candidate < 1
        candidate
      end

      def load_history_user_nicknames(events)
        return unless config.defined?(:user_lookup)

        ids = {}
        events.each do |event|
          next unless event.name.to_s == 'update'

          [:before, :after].each do |side|
            changes = event.data.fetch(side)
            Array(changes[:users] || changes['users']).each do |id|
              id = id.to_s
              next if @user_lookup_attempted&.key?(id)

              ids[id] = true
              return lookup_user_nicknames(ids.keys) if ids.size >= HISTORY_USER_LOOKUP_LIMIT
            end
          end
        end
        lookup_user_nicknames(ids.keys)
      end

      def lookup_user_nicknames(ids)
        return unless config.defined?(:user_lookup)

        @user_nicknames ||= {}
        @user_lookup_attempted ||= {}
        missing_ids = ids.uniq.reject { |id| @user_lookup_attempted.key?(id) }
        return if missing_ids.empty?

        missing_ids.each { |id| @user_lookup_attempted[id] = true }
        config.get(:user_lookup, missing_ids).each do |user|
          user = user_to_hash(user)
          @user_nicknames[user[:id]] = user[:nickname]
        end
      rescue StandardError
        @user_lookup_failed = true
      end

      def user_to_hash(user)
        # Only expose the fields needed by the selector, even if a callback
        # returns additional application-specific attributes.
        id = user[:id] || user['id']
        nickname = user[:nickname] || user['nickname']
        raise ArgumentError, 'Users must have an id and nickname' if id.nil? || nickname.to_s.empty?

        { id: id.to_s, nickname: nickname.to_s }
      end

      def update
        enrollment = parse_enrollment!
        rollout = config.get(:instance)
        actor = config.get(:actor, scope: self)

        with_rollout_context(rollout, actor: actor) do
          rollout.with_feature(params[:feature_name]) do |feature|
            validate_feature_version!(feature, enrollment)
            feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
            feature.groups = (params[:groups] || []).reject(&:empty?).map(&:to_sym)
            apply_enrollment!(feature, enrollment)
            feature.data["description"] = params[:description]
            feature.data["updated_at"] = Time.now.to_i
          end
        end

        redirect_location = feature_path(params[:feature_name])
        if params.key?(:page) || params.key?(:per_page)
          per_page = parse_users_per_page(params[:per_page])
          after_feature = config.get(:instance).get(params[:feature_name])
          total_pages = [ (after_feature.users.map(&:to_s).uniq.size.to_f / per_page).ceil, 1 ].max
          page = parse_users_page(params[:page], total_pages)
          redirect_location = "#{feature_path(params[:feature_name])}?#{Rack::Utils.build_query('page' => page, 'per_page' => per_page)}"
        end
        redirect_to redirect_location
      rescue StaleFeature => error
        query = Rack::Utils.build_query(error: error.message)
        redirect_to("#{feature_path(params[:feature_name])}?#{query}")
      rescue InvalidEnrollment
        bad_request(StandardError.new('invalid enrollment update'))
      end

      # Delta mode is only the scalar marker "1" plus a real fingerprint.
      # Any other present marker is rejected so it cannot fall through to a
      # legacy full-list replacement. Legacy replacement runs only when the
      # marker is absent, and only for a scalar string.
      def parse_enrollment!
        if params.key?(:user_changes)
          raise InvalidEnrollment unless params[:user_changes] == '1'
          raise InvalidEnrollment unless params[:feature_version].is_a?(String) && !params[:feature_version].empty?
          additions = parse_delta_ids(params[:users_to_add])
          removals = parse_delta_ids(params[:users_to_remove])
          raise InvalidEnrollment if additions.nil? || removals.nil?
          return [:delta, additions, removals]
        end

        return nil unless params.key?(:users)

        users = params[:users]
        return nil if users.nil?
        raise InvalidEnrollment unless users.is_a?(String)
        [:legacy, users]
      end

      def apply_enrollment!(feature, enrollment)
        return if enrollment.nil?

        kind, *payload = enrollment
        if kind == :delta
          additions, removals = payload
          current = feature.users.map { |id| id.to_s }.uniq
          feature.users = (current + additions - removals).uniq.sort
        else
          feature.users = payload.fetch(0).split(',').map(&:strip).reject(&:empty?).uniq.sort
        end
      end

      def parse_delta_ids(value)
        return [] if value.nil?
        return nil unless value.is_a?(String) || value.is_a?(Array)
        list = value.is_a?(Array) ? value : value.to_s.split(',')
        return nil unless list.all? { |entry| entry.is_a?(String) }
        list.map(&:strip).reject(&:empty?)
      rescue StandardError
        nil
      end

      def validate_feature_version!(feature, enrollment = nil)
        if enrollment&.first == :delta
          version = params[:feature_version]
          raise InvalidEnrollment unless version.is_a?(String) && !version.empty?
          if version != feature_version(feature)
            raise StaleFeature, STALE_FEATURE_MESSAGE
          end
          return
        end

        stale = if params.key?(:feature_version)
          params[:feature_version].to_s != feature_version(feature)
        else
          feature.data['updated_at'] && params[:last_updated_at].to_s != feature.data['updated_at'].to_s
        end
        raise StaleFeature, STALE_FEATURE_MESSAGE if stale
      end

      def activate_percentage
        rollout = config.get(:instance)
        actor = config.get(:actor, scope: self)

        with_rollout_context(rollout, actor: actor) do
          rollout.with_feature(params[:feature_name]) do |feature|
            feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
            feature.data["updated_at"] = Time.now.to_i
          end
        end

        redirect_to index_path
      end

      def delete_feature
        rollout = config.get(:instance)
        actor = config.get(:actor, scope: self)

        with_rollout_context(rollout, actor: actor) do
          rollout.delete(params[:feature_name])
        end

        redirect_to index_path
      end

      def not_found
        response.status = 404
        response['content-type'] = 'text/plain'
        response['x-cascade'] = 'pass'
        response.write('Not Found')
        response.finish
      end

      def bad_request(error)
        response.status = 400
        response['content-type'] = 'text/plain'
        response.write("Bad Request: #{error.message}")
        response.finish
      end

      def build_params(route_params)
        route_params = route_params.transform_values { |value| Rack::Utils.unescape_path(value) }

        request.params.merge(route_params).each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = value
          hash[key.to_sym] = value
        end
      end

      # Mirrors Sinatra's own `redirect`: browsers replaying a 302 after a
      # non-GET request may re-issue the original method, so redirects away
      # from a POST use 303 See Other instead.
      def redirect_to(location)
        http_version = request.env['SERVER_PROTOCOL'] || request.env['HTTP_VERSION']
        status = (http_version == 'HTTP/1.1' && request.request_method != 'GET') ? 303 : 302
        response.redirect(location, status)
      end

      def json(data)
        response.headers.delete('x-frame-options')
        response.headers.delete('x-xss-protection')
        response['content-type'] = 'application/json'
        response.write(data.to_json)
      end

      # Exposed so `Rollout::UI.configure { actor { env[...] } }` /
      # `actor { session[...] }` blocks keep working when instance_eval'd
      # against this dispatcher, matching Sinatra's own request-scoped
      # `env`/`session` helpers.
      def env
        request.env
      end

      def session
        request.session
      end

      def render_view(name)
        response['content-type'] = 'text/html;charset=utf-8'
        response.write(erb(name))
      end

      # Called from within views to render a partial, e.g.
      # `<%= erb :"features/partials/event_log", layout: false, locals: { events: events } %>`
      def erb(name, layout: true, locals: {})
        return render_template(name, locals) unless layout

        render_template(:layout, locals) { render_template(name, locals) }
      end

      def render_template(name, locals = {}, &block)
        path = File.join(VIEWS_PATH, "#{name}.erb")
        template_source = (TEMPLATE_CACHE[name] ||= ERB.new(File.read(path), trim_mode: '-').src)

        template_binding = binding
        locals.each { |key, value| template_binding.local_variable_set(key, value) }
        template_binding.eval(template_source, path)
      end
    end
  end
end
