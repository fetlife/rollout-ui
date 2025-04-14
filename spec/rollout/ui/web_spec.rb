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

  describe "CSRF Protection" do
    it "blocks POST without authenticity_token" do
      get "/features/new"

      post "/features/new", { name: "beta_feature" }

      expect(last_response.status).to eq(403)
    end

    it "blocks POST with invalid authenticity_token" do
      get "/features/new"

      post "/features/new", {
        name: "fake_feature",
        authenticity_token: "invalid-token"
      }

      expect(last_response.status).to eq(403)
    end

    it "allows POST with valid authenticity_token" do
      get "/features/new"
      token = last_request.env['rack.session'][:csrf]

      post "/features/new", {
        name: "secure_feature",
        authenticity_token: token
      }

      expect(last_response.status).to eq(302)
      follow_redirect!
      expect(last_response.body).to include("secure_feature")
    end

    it "blocks POST to update feature without authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"

      post "/features/test_feature", {
        percentage: 50,
        groups: ["test_group"]
      }

      expect(last_response.status).to eq(403)
      ROLLOUT.delete(:test_feature)
    end

    it "blocks POST to update feature with invalid authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"

      post "/features/test_feature", {
        percentage: 50,
        groups: ["test_group"],
        authenticity_token: "invalid-token"
      }

      expect(last_response.status).to eq(403)
      ROLLOUT.delete(:test_feature)
    end

    it "allows POST to update feature with valid authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"
      token = last_request.env['rack.session'][:csrf]

      post "/features/test_feature", {
        percentage: 50,
        groups: ["test_group"],
        authenticity_token: token
      }

      expect(last_response.status).to eq(302)
      follow_redirect!
      expect(last_response.body).to include("test_feature")
      ROLLOUT.delete(:test_feature)
    end

    it "blocks POST to delete feature without authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"

      post "/features/test_feature/delete"

      expect(last_response.status).to eq(403)
      ROLLOUT.delete(:test_feature)
    end

    it "blocks POST to delete feature with invalid authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"

      post "/features/test_feature/delete", {
        authenticity_token: "invalid-token"
      }

      expect(last_response.status).to eq(403)
      ROLLOUT.delete(:test_feature)
    end

    it "allows POST to delete feature with valid authenticity_token" do
      ROLLOUT.activate(:test_feature)
      get "/features/test_feature"
      token = last_request.env['rack.session'][:csrf]

      post "/features/test_feature/delete", {
        authenticity_token: token
      }

      expect(last_response.status).to eq(302)
      follow_redirect!
      expect(last_response.body).not_to include("test_feature")
    end
  end
end
