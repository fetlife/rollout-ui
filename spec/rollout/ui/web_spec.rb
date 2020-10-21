require 'spec_helper'
ENV['APP_ENV'] = 'test'
RSpec.describe 'Web UIp' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web
  end

  it "renders index html" do
    get '/'
    expect(last_response.body.include?('Rollout UI'))
    expect(last_response.status == 200)
  end

  it "renders index json" do
    ROLLOUT.activate(:fake_test_feature_for_rollout_ui_webspec)
    header 'Accept', 'application/json'
    get '/'
    expect(last_response.status == 200)
    expect(last_response.headers['Content-Type'] == 'application/json')
    response = JSON.parse(last_response.body)
    expected_response = {
      "data"=>{},
      "groups"=>[],
      "name"=>"fake_test_feature_for_rollout_ui_webspec",
      "percentage"=>100.0
    }
    expect(response).to(include(expected_response))
    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end

  it "renders index json filtered by user and group" do
    ROLLOUT.deactivate(:fake_test_feature_for_rollout_ui_webspec)
    ROLLOUT.activate_user(:fake_test_feature_for_rollout_ui_webspec, 'fake_user')
    ROLLOUT.activate_group(:fake_test_feature_for_rollout_ui_webspec, :fake_group)

    header 'Accept', 'application/json'
    get '/?user=different_user'
    expect(last_response.status == 200)
    expect(last_response.headers['Content-Type'] == 'application/json')
    response = JSON.parse(last_response.body)
    expect(response == [])

    expected_feature = {
      "data" => {},
      "groups" => ["fake_group"],
      "name" => "fake_test_feature_for_rollout_ui_webspec",
      "percentage" => 0.0
    }
    header 'Accept', 'application/json'
    get '/?user=fake_user'
    expect(last_response.status == 200)
    expect(last_response.headers['Content-Type'] == 'application/json')
    response = JSON.parse(last_response.body)
    expect(response).to(include(expected_feature))

    header 'Accept', 'application/json'
    get '/?group=fake_group'
    expect(last_response.status == 200)
    expect(last_response.headers['Content-Type'] == 'application/json')
    response = JSON.parse(last_response.body)
    expect(response).to(include(expected_feature))

    ROLLOUT.deactivate_user(:fake_test_feature_for_rollout_ui_webspec, 'fake_user')
    ROLLOUT.deactivate_group(:fake_test_feature_for_rollout_ui_webspec, :fake_group)
    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end

  it "renders show html" do
    get '/features/test'
    expect(last_response.body.include?('Rollout UI'))
    expect(last_response.body.include?('test'))
    expect(last_response.status == 200)
  end

  it "renders show json" do
    ROLLOUT.activate(:fake_test_feature_for_rollout_ui_webspec)
    header 'Accept', 'application/json'
    get '/features/fake_test_feature_for_rollout_ui_webspec'
    expect(last_response.status == 200)
    expect(last_response.headers['Content-Type'] == 'application/json')
    response = JSON.parse(last_response.body)
    expected_response = {
      "data"=>{},
      "groups"=>[],
      "name"=>"fake_test_feature_for_rollout_ui_webspec",
      "percentage"=>100.0
    }
    expect(expected_response == response)
    ROLLOUT.delete(:fake_test_feature_for_rollout_ui_webspec)
  end
end