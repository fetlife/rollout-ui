require 'spec_helper'

ENV['APP_ENV'] = 'test'

RSpec.describe 'Web UI' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.new
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

  it "decodes percent-encoded feature names from the path" do
    header 'Accept', 'application/json'

    get '/features/dark%20mode'

    expect(last_response).to be_ok
    response = JSON.parse(last_response.body)
    expect(response['name']).to eq('dark mode')
  end

  it "responds to HEAD requests like the equivalent GET, minus the body" do
    get '/'
    get_status = last_response.status

    head '/'

    expect(last_response.status).to eq(get_status)
    expect(last_response.body).to eq('')
  end

  it "responds at the exact mount point when Rack::URLMap strips the prefix" do
    mounted = Rack::URLMap.new('/admin/rollout' => Rollout::UI::Web.new)

    response = Rack::MockRequest.new(mounted).get('/admin/rollout')

    expect(response).to be_ok
    expect(response.body).to include('Rollout UI')
  end

  it "sets X-Cascade: pass on 404s so a mounting app can keep matching routes" do
    get '/this-route-does-not-exist'

    expect(last_response.status).to eq(404)
    expect(last_response.headers['X-Cascade']).to eq('pass')
  end

  it "returns 400 for malformed query parameters instead of raising" do
    get '/?%'

    expect(last_response.status).to eq(400)
  end

  it "sets baseline security headers on HTML responses but omits framing headers from JSON" do
    get '/'
    expect(last_response.headers['X-Content-Type-Options']).to eq('nosniff')
    expect(last_response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
    expect(last_response.headers['X-XSS-Protection']).to eq('1; mode=block')

    header 'Accept', 'application/json'
    get '/'
    expect(last_response.headers['X-Content-Type-Options']).to eq('nosniff')
    expect(last_response.headers.key?('X-Frame-Options')).to be false
    expect(last_response.headers.key?('X-XSS-Protection')).to be false
  end

  it "updates a feature via POST and redirects (303) to its show page" do
    post '/features/post_round_trip_feature',
         { percentage: '42', description: 'a test feature' },
         'SERVER_PROTOCOL' => 'HTTP/1.1'

    expect(last_response.status).to eq(303)
    expect(last_response.headers['Location']).to include('/features/post_round_trip_feature')

    feature = ROLLOUT.get(:post_round_trip_feature)
    expect(feature.percentage).to eq(42.0)
    expect(feature.data['description']).to eq('a test feature')

    ROLLOUT.delete(:post_round_trip_feature)
  end

  it "evaluates the configured actor block with request env/session access, matching Sinatra's own helpers" do
    original_actor_block = Rollout::UI.config.instance_variable_get(:@blocks)[:actor]
    Rollout::UI.configure { actor { env['HTTP_USER_AGENT'] } }

    header 'User-Agent', 'test-agent'
    expect do
      post '/features/actor_env_test_feature/activate-percentage',
           { percentage: '50' },
           'SERVER_PROTOCOL' => 'HTTP/1.1'
    end.not_to raise_error
    expect(last_response.status).to eq(303)

    ROLLOUT.delete(:actor_env_test_feature)
    Rollout::UI.config.instance_variable_get(:@blocks)[:actor] = original_actor_block
  end
end
