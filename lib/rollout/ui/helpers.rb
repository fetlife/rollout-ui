require "sinatra"
require "rollout"

require "rollout/ui/version"

module Rollout::UI
  module Helpers
    def stylesheet_path(name)
      "#{request.script_name}/css/#{name}.css"
    end

    def index_path
      "#{request.script_name}/"
    end

    def new_feature_path
      "#{request.script_name}/features/new"
    end

    def feature_path(feature_name)
      "#{request.script_name}/features/#{feature_name}"
    end

    def delete_feature_path(feature_name)
      "#{request.script_name}/features/#{feature_name}/delete"
    end

    def activate_percentage_feature_path(feature_name, percentage)
      "#{request.script_name}/features/#{feature_name}/activate-percentage?percentage=#{percentage.to_f}"
    end

    def current_user
      @current_user ||= begin
        id = request.session["warden.user.user.key"].try(:[], 0).try(:[], 0)
        User.find_by(id: id) unless id.nil?
      end
    end

    def with_rollout_context(rollout, context)
      if rollout.respond_to?(:logging)
        rollout.logging.with_context(context) do
          yield
        end
      else
        yield
      end
    end

    def config
      Rollout::UI.config
    end

    def time_ago(time)
      return '' unless time

      diff = (Time.now-time).to_i

      case diff
      when 0 then 'just now'
      when 1 then 'a second ago'
      when 2..59 then diff.to_s+' seconds ago'
      when 60..119 then 'a minute ago' #120 = 2 minutes
      when 120..3540 then (diff/60).to_i.to_s+' minutes ago'
      when 3541..7100 then 'an hour ago' # 3600 = 1 hour
      when 7101..82800 then ((diff+99)/3600).to_i.to_s+' hours ago'
      when 82801..172000 then 'a day ago' # 86400 = 1 day
      when 172001..518400 then ((diff+800)/(60*60*24)).to_i.to_s+' days ago'
      when 518400..1036800 then 'a week ago'
      else ((diff+180000)/(60*60*24*7)).to_i.to_s+' weeks ago'
      end
    end

    def format_change_key(key)
      key.to_s.gsub('data.', '')
    end

    def format_change_value(value)
      case value
      when Array
        "[#{value.join(', ')}]"
      when String, nil
        "'#{value}'"
      else
        value
      end
    end

    def json_request?
      request.env['HTTP_ACCEPT'] == 'application/json'
    end

    # Filters features by user and group if those params are provided
    def filtered_features(rollout, feature_names)
      feature_names.select do |feature_name|
        feature = rollout.get(feature_name)
        user_match = params[:user].nil? || feature.users.member?(params[:user])
        group_match = params[:group].nil? || feature.groups.member?(params[:group].to_sym)
        user_match && group_match
      end
    end

    # Returns a hash of feature data to be rendered as json
    def feature_to_hash(feature)
      {
        data: feature.data,
        groups: feature.groups,
        name: feature.name,
        percentage: feature.percentage
      }
    end

    def sanitized_name(feature_name)
      Rack::Utils.escape_html(feature_name)
    end
  end
end
