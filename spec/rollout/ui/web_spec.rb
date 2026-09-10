require 'spec_helper'

ENV['APP_ENV'] = 'test'

RSpec.describe 'Web UI' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.tap do |app|
      app.set :host_authorization, skip: true
    end
  end

  it "renders index html" do
    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).to include('Rollout UI')
  end

  it "renders index json" do
    ROLLOUT.activate(:fake_test_feature_for_rollout_ui_webspec)
    header 'Accept', 'application/json'

    get '/'

    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json')
    response = JSON.parse(last_response.body)
    expected_response = {
      "data"=>{},
      "groups"=>[],
      "name"=>"fake_test_feature_for_rollout_ui_webspec",
      "percentage"=>100.0
    }
    expect(response).to include(expected_response)
    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end

  context "with global history" do
    let(:rollout) { Rollout.new(REDIS, logging: { global: true }) }
    let(:feature_name) { :history_feature_for_rollout_ui_webspec }

    around do |example|
      previous_instance = Rollout::UI.config.get(:instance)
      history_instance = rollout
      Rollout::UI.configure { instance { history_instance } }
      example.run
    ensure
      Rollout::UI.configure { instance { previous_instance } }
      rollout.delete(feature_name)
    end

    it "links existing features in history" do
      rollout.activate(feature_name)

      get '/'

      expect(last_response).to be_ok
      history = last_response.body.split('History</h2>', 2).fetch(1)
      expect(history).to match(%r{<a\b[^>]*href="/features/#{feature_name}"[^>]*>#{feature_name}</a>})
    end

    it "keeps deleted feature names as plain text without recreating them" do
      rollout.activate(feature_name)
      rollout.delete(feature_name)

      expect { get '/' }.not_to change { rollout.features }

      expect(last_response).to be_ok
      history = last_response.body.split('History</h2>', 2).fetch(1)
      expect(history).to match(%r{<td\b[^>]*>#{feature_name}</td>})
      expect(history).not_to include("href=\"/features/#{feature_name}\"")
      expect(rollout.features).not_to include(feature_name)
      expect(REDIS.exists?("feature:#{feature_name}")).to be false
    end

    context "with HTML in a deleted feature name" do
      let(:feature_name) { :'<script>alert(42)</script>' }

      it "escapes the name in history" do
        rollout.activate(feature_name)
        rollout.delete(feature_name)

        get '/'

        expect(last_response).to be_ok
        history = last_response.body.split('History</h2>', 2).fetch(1)
        expect(history).to match(%r{<td\b[^>]*>&lt;script&gt;alert\(42\)&lt;/script&gt;</td>})
        expect(history).not_to include(feature_name.to_s)
      end
    end
  end

  it "renders index json filtered by user and group" do
    ROLLOUT.deactivate(:fake_test_feature_for_rollout_ui_webspec)
    ROLLOUT.activate_user(:fake_test_feature_for_rollout_ui_webspec, 'fake_user')
    ROLLOUT.activate_group(:fake_test_feature_for_rollout_ui_webspec, :fake_group)

    header 'Accept', 'application/json'
    get '/?user=different_user'
    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json')
    response = JSON.parse(last_response.body)
    expect(response).to be_empty

    expected_feature = {
      "data" => {},
      "groups" => ["fake_group"],
      "name" => "fake_test_feature_for_rollout_ui_webspec",
      "percentage" => 0.0
    }
    header 'Accept', 'application/json'
    get '/?user=fake_user'
    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json')
    response = JSON.parse(last_response.body)
    expect(response).to include(expected_feature)

    header 'Accept', 'application/json'
    get '/?group=fake_group'
    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json')
    response = JSON.parse(last_response.body)
    expect(response).to include(expected_feature)

    ROLLOUT.deactivate_user(:fake_test_feature_for_rollout_ui_webspec, 'fake_user')
    ROLLOUT.deactivate_group(:fake_test_feature_for_rollout_ui_webspec, :fake_group)
    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end

  it "rescapes javascript in the action index" do
    ROLLOUT.activate(:'<script>alert(1)</script>')

    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).to include('Rollout UI') & (include("&amp;lt;script&amp;gt;alert(1)&amp;lt;&amp;") | include('&lt;script&gt;alert(1)&lt;/script&gt;'))
  end

  it "renders show html" do
    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('Rollout UI') & include('test')
  end

  it "escapes javascript in the action show" do
    get "/features/'+alert(1)+'"

    expect(last_response).to be_ok
    expect(last_response.body).to include('Rollout UI') & (include("&amp;#x27;+alert(1)+&amp;#x27;") | include("&#39;+alert(1)+&#39;"))
  end

  it "renders show json" do
    ROLLOUT.activate(:fake_test_feature_for_rollout_ui_webspec)
    header 'Accept', 'application/json'

    get '/features/fake_test_feature_for_rollout_ui_webspec'

    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json')
    response = JSON.parse(last_response.body)
    expected_response = {
      "data"=>{},
      "groups"=>[],
      "name"=>"fake_test_feature_for_rollout_ui_webspec",
      "percentage"=>100.0
    }
    expect(expected_response).to eq response

    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end
end
