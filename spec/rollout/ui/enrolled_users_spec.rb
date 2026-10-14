require 'spec_helper'
require 'cgi'

RSpec.describe 'Enrolled users pagination' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.new
  end

  let(:config) { Rollout::UI::Config.new }
  let(:search) do
    ->(query, limit) do
      [
        { id: '123', nickname: 'alice' },
        { id: '999', nickname: 'zoe' },
      ].take(limit)
    end
  end
  let(:lookup) do
    ->(ids) do
      ids.map { |id| { id: id, nickname: "user#{id}" } }
    end
  end

  let(:feature_name) { 'enrolled_users_spec' }
  let(:path) { "/features/#{feature_name}" }
  let(:users_path) { "/features/#{feature_name}/users" }

  before do
    config.instance { ROLLOUT }
    config.user_search(&search)
    config.user_lookup(&lookup)
    allow(Rollout::UI).to receive(:config).and_return(config)
    ROLLOUT.delete(feature_name)
  end

  after { ROLLOUT.delete(feature_name) }

  def feature_version_from_page
    get path
    expect(last_response).to be_ok
    last_response.body[/name="feature_version" value="([^"]+)"/, 1]
  end

  def snapshot_feature
    feature = ROLLOUT.adapter.fetch_feature(feature_name)
    {
      users: feature.users.map(&:to_s),
      groups: feature.groups.map(&:to_s),
      percentage: feature.percentage,
      data: feature.data.dup,
      events: ROLLOUT.logging.events(feature_name).count,
    }
  end

  def expect_unchanged(before)
    feature = ROLLOUT.adapter.fetch_feature(feature_name)
    expect(feature.users.map(&:to_s)).to eq(before[:users])
    expect(feature.groups.map(&:to_s)).to eq(before[:groups])
    expect(feature.percentage).to eq(before[:percentage])
    expect(feature.data).to eq(before[:data])
    expect(ROLLOUT.logging.events(feature_name).count).to eq(before[:events])
    expect(last_response.status).to eq(400)
  end

  it 'returns paginated enrolled users JSON with no-store and bounded lookups' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..26).map(&:to_s) }

    expect(lookup).to receive(:call).once.with((1..26).map(&:to_s).sort.first(10)).and_call_original

    get users_path, page: 1, per_page: 10
    body = JSON.parse(last_response.body)

    expect(last_response).to be_ok
    expect(last_response.headers['Cache-Control']).to eq('no-store')
    expect(body['users'].map { |user| user['id'] }).to eq((1..26).map(&:to_s).sort.first(10))
    expect(body['total']).to eq(26)
    expect(body['page']).to eq(1)
    expect(body['per_page']).to eq(10)
    expect(body['total_pages']).to eq(3)
    expect(body['feature_version']).to match(/\A[0-9a-f]{64}\z/)
    expect(body['lookup_failed']).to be false
  end

  it 'handles zero, 25, 26, and 151 enrolled users boundaries' do
    [0, 25, 26].each do |count|
      ROLLOUT.delete(feature_name)
      ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..count).map(&:to_s) } unless count.zero?

      get users_path
      body = JSON.parse(last_response.body)
      expect(body['total']).to eq(count)
      expect(body['page']).to eq(1)
      expect(body['per_page']).to eq(25)
      expect(body['total_pages']).to eq([ (count.to_f / 25).ceil, 1 ].max)
      expect(body['users'].size).to eq([ count, 25 ].min)
    end

    ROLLOUT.delete(feature_name)
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..151).map(&:to_s) }
    get users_path, per_page: 50
    body = JSON.parse(last_response.body)
    expect(body['total']).to eq(151)
    expect(body['total_pages']).to eq(4)
    expect(body['per_page']).to eq(50)
  end

  it 'parses page and per-page safely' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..26).map(&:to_s) }

    get users_path, page: 'abc', per_page: '1000'
    body = JSON.parse(last_response.body)
    expect(body['page']).to eq(1)
    expect(body['per_page']).to eq(25)

    get users_path, page: [1, 2], per_page: { a: 1 }
    body = JSON.parse(last_response.body)
    expect(body['page']).to eq(1)
    expect(body['per_page']).to eq(25)

    get users_path, page: '0', per_page: '10'
    body = JSON.parse(last_response.body)
    expect(body['page']).to eq(1)

    get users_path, page: '999', per_page: '10'
    body = JSON.parse(last_response.body)
    expect(body['page']).to eq(3)
  end

  it 'retains unknown IDs and reports lookup failures as ID-based labels' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[123 456] }
    allow(lookup).to receive(:call).and_raise('lookup unavailable')

    get users_path, per_page: 10
    body = JSON.parse(last_response.body)

    expect(body['lookup_failed']).to be true
    expect(body['users'].map { |user| user['id'] }).to eq(%w[123 456])
    expect(body['users'].map { |user| user['nickname'] }).to eq(['Unknown user (#123)', 'Unknown user (#456)'])
  end

  it 'serves enrolled users and search under a Rack mount' do
    ROLLOUT.activate_user(feature_name, '123')

    mounted = Rack::MockRequest.new(Rack::URLMap.new('/admin/rollout' => app))
    response = mounted.get("/admin/rollout#{users_path}?page=1&per_page=10")
    expect(response).to be_ok
    expect(JSON.parse(response.body)['users'].first['id']).to eq('123')

    response = mounted.get("/admin/rollout/features/#{feature_name}/users/search?q=alice")
    expect(response).to be_ok
    expect(JSON.parse(response.body)['users']).not_to be_nil
  end

  it 'keeps global search responses unchanged' do
    get '/users/search', q: 'alice'

    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)).to eq('users' => [{ 'id' => '123', 'nickname' => 'alice' },
                                                           { 'id' => '999', 'nickname' => 'zoe' }])
    expect(JSON.parse(last_response.body)).not_to have_key('feature_version')
  end

  it 'marks scoped search results enrolled based on full membership' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..151).map(&:to_s) }

    get "/features/#{feature_name}/users/search", q: 'alice'
    body = JSON.parse(last_response.body)

    expect(last_response).to be_ok
    expect(last_response.headers['Cache-Control']).to eq('no-store')
    expect(body['feature_version']).to match(/\A[0-9a-f]{64}\z/)
    expect(body['users']).to eq([{ 'id' => '123', 'nickname' => 'alice', 'enrolled' => true },
                                 { 'id' => '999', 'nickname' => 'zoe', 'enrolled' => false }])
  end

  it 'applies user deltas across pages while preserving untouched users' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..30).map(&:to_s) }
    version = feature_version_from_page

    post path, user_changes: '1', users_to_add: '31', users_to_remove: '1',
      page: '1', per_page: '25', feature_version: version

    expect(last_response).to be_redirect
    expect(ROLLOUT.get(feature_name).users).to eq((2..31).map(&:to_s).sort)
    expect(last_response.location).to include('page=1')
    expect(last_response.location).to include('per_page=25')
  end

  it 'preserves all users for empty deltas and is idempotent for duplicates' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2 3] }
    version = feature_version_from_page
    events_before = ROLLOUT.logging.events(feature_name).count

    post path, user_changes: '1', users_to_add: '', users_to_remove: '',
      feature_version: version
    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 2 3])

    version = feature_version_from_page
    post path, user_changes: '1', users_to_add: '1,1', users_to_remove: '2',
      feature_version: version
    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 3])
  end

  it 'lets removals win when an ID is both added and removed' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2] }
    version = feature_version_from_page

    post path, user_changes: '1', users_to_add: '2,3', users_to_remove: '2',
      feature_version: version

    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 3])
  end

  it 'supports legacy full-list submissions without a delta marker' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2 3] }
    version = feature_version_from_page

    post path, users: '5, 6', percentage: '25', feature_version: version

    expect(last_response).to be_redirect
    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[5 6])
  end

  it 'rejects stale full-state versions without changing state or history' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2] }
    version = feature_version_from_page
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[9] }
    state_before = ROLLOUT.adapter.fetch_feature(feature_name)
    events_before = ROLLOUT.logging.events(feature_name).count

    post path, user_changes: '1', users_to_add: '3', users_to_remove: '',
      feature_version: version

    expect(last_response).to be_redirect
    expect(last_response.location).to include('error=')
    state_after = ROLLOUT.adapter.fetch_feature(feature_name)
    expect(state_after.users).to eq(state_before.users)
    expect(ROLLOUT.logging.events(feature_name).count).to eq(events_before)
  end

  it 'rejects malformed nested enrollment payloads without writes' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2] }
    version = feature_version_from_page
    events_before = ROLLOUT.logging.events(feature_name).count

    post path, user_changes: '1', 'users_to_remove' => { 'bad' => 'value' },
      feature_version: version

    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 2])
    expect(ROLLOUT.logging.events(feature_name).count).to eq(events_before)
  end

  it 'omits page params and keeps bare redirect for old update requests' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1] }
    version = feature_version_from_page

    post path, percentage: '25', feature_version: version

    expect(last_response.location).to eq(path)
  end

  it 'returns only the requested enrollment page' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..26).map(&:to_s) }

    get users_path, page: '2', per_page: '10'
    body = JSON.parse(last_response.body)

    expect(body['users'].map { |user| user['id'] }).to eq((1..26).map(&:to_s).sort[10, 10])
    expect(body['users'].map { |user| user.keys }.uniq).to eq([%w[id nickname]])
    expect(body['page']).to eq(2)
    expect(body['total']).to eq(26)
    expect(body['total_pages']).to eq(3)
  end

  it 'renders the selected enrollment page from the HTML show action' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = (1..26).map(&:to_s) }

    get path, page: 2, per_page: 10

    expect(last_response).to be_ok
    expect(last_response.body).to include('data-page="2"', 'data-per-page="10"', 'data-total="26"', 'data-total-pages="3"')
    expect(last_response.body.scan('data-user-id=').count).to eq(10)
  end

  it 'does not let a feature_name query param change global search or read the feature' do
    ROLLOUT.activate_user(feature_name, '123')
    expect(ROLLOUT).not_to receive(:get)
    expect(ROLLOUT.adapter).not_to receive(:fetch_feature)
    expect(search).to receive(:call).with('alice', 20).and_call_original

    get '/users/search', q: 'alice', feature_name: feature_name

    expect(last_response).to be_ok
    expect(last_response.headers['Cache-Control']).to eq('no-store')
    expect(JSON.parse(last_response.body)).to eq('users' => [{ 'id' => '123', 'nickname' => 'alice' },
                                                             { 'id' => '999', 'nickname' => 'zoe' }])
    expect(last_response.body).not_to include('enrolled', 'feature_version', feature_name)
  end

  it 'strips extra attributes from scoped search and marks full-membership enrollment' do
    ROLLOUT.activate_user(feature_name, 123)
    allow(search).to receive(:call).and_return([{ id: 123, nickname: 'alice', email: 'private@example.test' }])

    get "/features/#{feature_name}/users/search", q: 'alice'
    body = JSON.parse(last_response.body)

    expect(body['users']).to eq([{ 'id' => '123', 'nickname' => 'alice', 'enrolled' => true }])
    expect(body['feature_version']).to match(/\A[0-9a-f]{64}\z/)
    expect(last_response.body).not_to include('private@example.test')
  end

  it 'accepts no-JS checkbox removals without trusting a submitted users list' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2 3 4] }
    version = feature_version_from_page

    post path, user_changes: '1', users: '9', users_to_add: '5, 5', users_to_remove: ['2', '4'],
      feature_version: version

    expect(last_response).to be_redirect
    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 3 5])
  end

  it 'rejects a delta update that omits feature_version even when the legacy timestamp matches' do
    ROLLOUT.with_feature(feature_name) do |feature|
      feature.users = %w[1 2]
      feature.percentage = 25
      feature.data['description'] = 'keep'
      feature.data['updated_at'] = 1_800_000_000
    end
    stored = ROLLOUT.get(feature_name)
    expect(stored.data['updated_at'].to_s).to eq('1800000000')
    before = snapshot_feature

    post path, user_changes: '1', users_to_add: '9', percentage: '90', description: 'changed',
      last_updated_at: stored.data['updated_at'].to_s

    expect_unchanged(before)
    expect(last_response.body).not_to include('9')
  end

  it 'rejects a delta update that omits feature_version when the feature has no timestamp' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2] }
    expect(ROLLOUT.get(feature_name).data['updated_at']).to be_nil
    before = snapshot_feature

    post path, user_changes: '1', users_to_add: '9', percentage: '40', description: 'changed'

    expect_unchanged(before)
  end

  it 'rejects a present delta marker that is not the scalar string 1 without applying users' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2]; feature.percentage = 25 }
    version = feature_version_from_page
    before = snapshot_feature
    [['1'], { 'bad' => '1' }, '', 'yes', '0', ' 1'].each do |marker|
      post path, user_changes: marker, users: '9', percentage: '80', feature_version: version

      expect(last_response.status).to eq(400), "expected #{marker.inspect} to be rejected, got #{last_response.status}"
      expect_unchanged(before)
      expect(last_response.body).not_to include('9')
    end
  end

  it 'rejects a non-string legacy users list even with a valid fingerprint' do
    ROLLOUT.with_feature(feature_name) { |feature| feature.users = %w[1 2]; feature.percentage = 15 }
    version = feature_version_from_page
    before = snapshot_feature

    post path, users: ['new-user', 'other-user'], percentage: '80', feature_version: version
    expect_unchanged(before)
    expect(last_response.body).not_to include('new-user', 'other-user')

    post path, users: { 'id' => 'new-user' }, percentage: '80', feature_version: version
    expect_unchanged(before)
    expect(last_response.body).not_to include('new-user')
  end

  it 'retains the legacy timestamp fallback only when the delta marker is absent' do
    ROLLOUT.with_feature(feature_name) do |feature|
      feature.users = %w[1]
      feature.percentage = 10
      feature.data['updated_at'] = 42
    end

    post path, users: '1, 2', percentage: '10', last_updated_at: '42'

    expect(last_response).to be_redirect
    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[1 2])
  end
end