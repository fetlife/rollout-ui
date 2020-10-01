require "sinatra"
require "rollout"

require "rollout/ui/version"
require "rollout/ui/config"
require "rollout/ui/helpers"

module Rollout::UI
  class Web < Sinatra::Base
    set :static, true
    set :public_folder, File.dirname(__FILE__) + '/public'

    helpers Helpers

    get '/' do
      @rollout = config.get(:instance)
      @features = @rollout.features.sort_by(&:downcase)

      slim :'features/index'
    end

    get '/features/new' do
      slim :'features/new'
    end

    post '/features/new' do
      redirect feature_path(params[:name])
    end

    get '/features/:feature_name' do
      @rollout = config.get(:instance)
      @feature = @rollout.get(params[:feature_name])

      slim :'features/show'
    end

    post '/features/:feature_name' do
      rollout = config.get(:instance)
      actor = config.get(:actor, scope: self)

      with_rollout_context(rollout, actor: actor) do
        rollout.with_feature(params[:feature_name]) do |feature|
          feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
          feature.groups = (params[:groups] || []).reject(&:empty?).map(&:to_sym)
          if params[:users]
            feature.users = params[:users].split(',').map(&:strip).uniq.sort
          end
          feature.data.each do |name, old_val|
            new_val = params[name]

            # keep type the same (for integers/boolean/strings)
            new_val = if old_val.is_a? Integer
              new_val.to_i
            elsif !!old_val == old_val
              new_val == 'true' ? true : (new_val == 'false' ? false : !!new_val)
            else
              new_val
            end

            feature.data.update(name => new_val)
          end
        end
      end

      redirect feature_path(params[:feature_name])
    end

    post '/features/:feature_name/activate-percentage' do
      rollout = config.get(:instance)
      actor = config.get(:actor, scope: self)

      with_rollout_context(rollout, actor: actor) do
        rollout.with_feature(params[:feature_name]) do |feature|
          feature.percentage = params[:percentage].to_f.clamp(0.0, 100.0)
        end
      end

      redirect index_path
    end

    post '/features/:feature_name/delete' do
      @rollout = config.get(:instance)
      @rollout.delete(params[:feature_name])

      redirect index_path
    end
  end
end
