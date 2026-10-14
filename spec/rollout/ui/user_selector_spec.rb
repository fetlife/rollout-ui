require 'spec_helper'
require 'cgi'

RSpec.describe 'Nickname user selector' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.new
  end

  let(:config) { Rollout::UI::Config.new }
  let(:search) { ->(_query, _limit) { [{ id: 123, nickname: 'alice', email: 'private@example.test' }] } }
  let(:lookup) { ->(_ids) { [{ 'id' => '123', 'nickname' => 'alice' }] } }
  let(:feature_name) { 'nickname_selector_spec' }

  before do
    config.instance { ROLLOUT }
    config.user_search(&search)
    config.user_lookup(&lookup)
    allow(Rollout::UI).to receive(:config).and_return(config)
    ROLLOUT.delete(feature_name)
  end

  after { ROLLOUT.delete(feature_name) }

  it 'passes a trimmed nickname and limit to the callback and only returns IDs and nicknames' do
    expect(search).to receive(:call).with('alice', 20).and_call_original

    get '/users/search', q: ' alice '

    expect(last_response).to be_ok
    expect(last_response.headers).to include('Content-Type' => 'application/json', 'Cache-Control' => 'no-store')
    expect(JSON.parse(last_response.body)).to eq('users' => [{ 'id' => '123', 'nickname' => 'alice' }])
  end

  it 'does not call search for missing, blank, or short nicknames' do
    expect(search).not_to receive(:call)
    [nil, '', '  ', 'ab', ' ab '].each do |query|
      get '/users/search', q: query
      expect(last_response).to be_ok
      expect(JSON.parse(last_response.body)).to eq('users' => [])
    end
  end

  it 'supports Unicode nicknames' do
    expect(search).to receive(:call).with('猫猫猫', 20).and_call_original
    get '/users/search', q: '猫猫猫'
    expect(last_response).to be_ok
  end

  it 'rejects non-string and excessively long queries without calling search' do
    expect(search).not_to receive(:call)
    [['alice'], { nickname: 'alice' }, 'a' * 101].each do |query|
      get '/users/search', q: query
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)).to have_key('error')
    end
  end

  it 'respects configured minimum length and caps callback results' do
    config.user_search_min_length { 4 }
    config.user_search_limit { 2 }
    expect(search).to receive(:call).with('alic', 2).and_return(
      (1..3).map { |id| { id: id, nickname: "alice#{id}" } }
    )

    get '/users/search', q: 'ali'
    expect(JSON.parse(last_response.body)).to eq('users' => [])
    get '/users/search', q: 'alic'
    expect(JSON.parse(last_response.body)['users'].map { |user| user['id'] }).to eq(%w[1 2])
  end

  it 'bounds the configurable result limit' do
    config.user_search_limit { 1_000_000 }
    expect(search).to receive(:call).with('alice', 100).and_call_original
    get '/users/search', q: 'alice'
    expect(last_response).to be_ok
  end

  it 'returns a generic error when search fails, without leaking exception details' do
    allow(search).to receive(:call).and_raise('database credentials or private query details')
    get '/users/search', q: 'alice'
    expect(last_response.status).to eq(503)
    expect(last_response.body).to include('temporarily unavailable')
    expect(last_response.body).not_to include('credentials', 'private query')
  end

  it 'disables nickname search and retains ID-based editing without both callbacks' do
    [nil, :user_search, :user_lookup].each do |callback|
      plain_config = Rollout::UI::Config.new
      plain_config.instance { ROLLOUT }
      plain_config.public_send(callback) { [] } if callback
      allow(Rollout::UI).to receive(:config).and_return(plain_config)

      get '/users/search', q: 'alice'
      expect(last_response.status).to eq(404)
      get "/features/#{feature_name}"
      expect(last_response.body).to include('name="users_to_add"', 'name="user_changes" value="1"')
      expect(last_response.body).not_to include('id="user-selector"')
    end
  end

  it 'resolves selected IDs in a single batch and preserves unresolved users' do
    ROLLOUT.activate_user(feature_name, '123')
    ROLLOUT.activate_user(feature_name, '456')
    expect(lookup).to receive(:call).once.with(%w[123 456]).and_call_original
    expect(search).not_to receive(:call)

    get "/features/#{feature_name}", {}, 'SCRIPT_NAME' => '/admin/rollout'

    expect(last_response).to be_ok
    expect(last_response.body).to include('Users (<span id="enrolled-user-count">2</span>)')
    expect(last_response.body).not_to include('Users enabled through groups or percentage are not listed here.')
    expect(last_response.body).to include('data-user-id="123" data-nickname="alice"')
    expect(last_response.body).to include('data-user-id="456" data-nickname="Unknown user (#456)"')
    expect(last_response.body).to include('data-search-url="/admin/rollout/features/nickname_selector_spec/users/search"',
      'src="/admin/rollout/js/enrolled-users.js"', 'data-min-length="3"', 'data-limit="20"')
  end

  it 'escapes nickname markup in the initial selections' do
    nickname = %q{<script>alert("nickname")</script>}
    ROLLOUT.activate_user(feature_name, '123')
    allow(lookup).to receive(:call).and_return([{ id: 123, nickname: nickname }])

    get "/features/#{feature_name}"

    expect(last_response.body).to include("data-nickname=\"#{CGI.escapeHTML(nickname)}\"")
    expect(last_response.body).not_to include(nickname)
  end

  it 'preserves IDs and renders a notice when nickname lookup fails' do
    ROLLOUT.activate_user(feature_name, '123')
    allow(lookup).to receive(:call).and_raise('lookup failed')
    get "/features/#{feature_name}"

    expect(last_response).to be_ok
    expect(last_response.body).to include('Unknown user (#123)', 'Their user IDs are preserved.')
    expect(last_response.body).to include('name="users_to_remove[]" value="123"')
  end

  it 'does not look up users for an empty selection or JSON feature responses' do
    expect(lookup).not_to receive(:call)
    get "/features/#{feature_name}"
    expect(last_response).to be_ok
    ROLLOUT.activate_user(feature_name, '123')
    header 'Accept', 'application/json'
    get "/features/#{feature_name}"
    expect(last_response).to be_ok
  end

  it 'paginates large cohorts and only looks up the visible enrollment page' do
    ids = (1..151).map(&:to_s)
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = ids }
    silent = Rollout.new(adapter: Rollout::Adapters::Redis.new(REDIS))
    config.instance { silent }
    expect(lookup).to receive(:call).once.with(ids.sort.first(25)).and_call_original
    get "/features/#{feature_name}"
    expect(last_response.body).to include('id="enrolled-user-count">151</span>',
      'Page 1 of 7', 'id="user-selector"', 'name="users_to_add"')
    expect(last_response.body).not_to include('Showing 1–25 of 151 enrolled users', 'Type at least')
    expect(last_response.body.scan('data-user-id=').count).to eq(25)
    expect(last_response.body).not_to include('Only the count is shown', 'name="users"')
  end

  it 'serves search and JavaScript under a Rack mount' do
    mounted = Rack::MockRequest.new(Rack::URLMap.new('/admin/rollout' => app))
    response = mounted.get('/admin/rollout/users/search?q=alice')
    expect(response).to be_ok
    expect(JSON.parse(response.body)['users'].first['nickname']).to eq('alice')
    response = mounted.get('/admin/rollout/js/enrolled-users.js')
    expect(response).to be_ok
    expect(response.body).to include('AbortController')
    expect(response.headers['content-type']).to include('javascript')
  end

  it 'saves selected IDs through the existing form parameter' do
    post "/features/#{feature_name}", users: '456, 123, 123, ', percentage: '25'
    expect(last_response).to be_redirect
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456])
  end

  it 'clears all users when the selector submits an empty field' do
    ROLLOUT.activate_user(feature_name, '123')
    post "/features/#{feature_name}", users: ''
    expect(last_response).to be_redirect
    expect(ROLLOUT.get(feature_name).users).to eq([])
  end

  it 'preserves selected users when no users field is submitted' do
    ROLLOUT.activate_user(feature_name, '123')
    post "/features/#{feature_name}", percentage: '25'
    expect(last_response).to be_redirect
    expect(ROLLOUT.get(feature_name).users).to eq(['123'])
  end

  it 'preserves unresolved accounts when adding and removing users with a rendered form version' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[123 456] }
    get "/features/#{feature_name}"
    expect(last_response.body).to include('data-user-id="456" data-nickname="Unknown user (#456)"')
    version = last_response.body[/name="feature_version" value="([^"]+)"/, 1]

    post "/features/#{feature_name}", user_changes: '1', users_to_add: '789', percentage: '25', feature_version: version
    expect(last_response.location).to eq("/features/#{feature_name}")
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456 789])

    follow_redirect!
    expect(last_response.body).to include('Unknown user (#456)')
    version = last_response.body[/name="feature_version" value="([^"]+)"/, 1]
    post "/features/#{feature_name}", user_changes: '1', users_to_remove: ['123'], percentage: '25', feature_version: version

    expect(last_response.location).to eq("/features/#{feature_name}")
    expect(ROLLOUT.get(feature_name).users).to eq(%w[456 789])
  end

  it 'preserves all enrollments when updating other settings from a single page' do
    ids = (1..151).map(&:to_s)
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = ids }
    get "/features/#{feature_name}"
    version = last_response.body[/name="feature_version" value="([^"]+)"/, 1]

    post "/features/#{feature_name}", user_changes: '1', percentage: '25', description: 'Updated', feature_version: version

    expect(last_response.location).to eq("/features/#{feature_name}")
    expect(ROLLOUT.get(feature_name).users).to match_array(ids)
    expect(ROLLOUT.get(feature_name).data['description']).to eq('Updated')
  end
end
