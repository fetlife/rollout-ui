# frozen_string_literal: true

require 'bundler/setup'
require 'rollout/ui/api'
require 'rollout/adapters/active_record'
require 'rack/mock'
require 'rack/urlmap'
require 'puma'
require 'tmpdir'
require 'open3'
require 'rbconfig'

RSpec.describe Rollout::UI::API do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: File.join(directory, 'rollout.sqlite3'))
      Rollout::ActiveRecord::Schema.create(ActiveRecord::Base.connection)
      @adapter = Rollout::Adapters::ActiveRecord.new
      @rollout = Rollout.new(adapter: @adapter, logging: { history_length: 3, global: true })
      @api = described_class.new(instance: @rollout, environment: 'test')
      example.run
    ensure
      @server&.stop(true)
      @thread&.join
      ActiveRecord::Base.connection_pool.disconnect!
    end
  end

  def request(path, method: 'GET')
    status, headers, body = @api.call({ 'REQUEST_METHOD' => method, 'PATH_INFO' => path.split('?', 2).first,
      'QUERY_STRING' => path.split('?', 2)[1].to_s })
    [status, JSON.parse(body.join), headers]
  end

  def body(path)
    status, payload, headers = request(path)
    expect(status).to eq(200)
    expect(headers['cache-control']).to eq('no-store')
    payload
  end

  def change(name, percentage)
    @rollout.logging.with_context(actor: 'employee', nullable: nil) do
      @rollout.activate_percentage(name, percentage)
    end
  end

  def snapshot
    %w[rollout_features rollout_events].map do |table|
      ActiveRecord::Base.connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a
    end
  end

  def start_server
    api = @api
    authenticated = lambda do |env|
      if env['HTTP_AUTHORIZATION'] == 'Bearer integration-test'
        api.call(env)
      else
        [401, { 'content-type' => 'application/json', 'www-authenticate' => 'Bearer' }, ['{}']]
      end
    end
    app = Rack::URLMap.new('/internal/rollout/v1' => authenticated)
    @server = Puma::Server.new(app)
    @server.add_tcp_listener('127.0.0.1', 0)
    @thread = @server.run
    config = { profiles: { test: { url: "http://127.0.0.1:#{@server.binder.connected_ports.first}/internal/rollout/v1",
      environment: 'test', token_env: 'ROLLOUT_TEST_TOKEN', allow_http: true } } }
    @config = File.join(@directory, 'config.json')
    File.write(@config, JSON.generate(config), perm: 0o600)
  end

  def cli(*args, token: 'integration-test')
    start_server unless @server
    Open3.capture3({ 'ROLLOUT_TEST_TOKEN' => token }, RbConfig.ruby,
      File.expand_path('../rollout-cli/bin/rollout', __dir__), *args,
      '--config', @config, '--profile', 'test', '--json')
  end

  def cli_body(*args)
    stdout, stderr, status = cli(*args)
    expect([status.exitstatus, stderr]).to eq([0, ''])
    JSON.parse(stdout)
  end

  it 'runs all CLI commands through a mounted HTTP API with real state and no database writes' do
    change('chat', 25.5)
    @rollout.with_feature('chat') do |feature|
      feature.users = ['2', '10']
      feature.groups = [:staff, :all]
      feature.data = { 'nested' => { 'value' => nil }, 'enabled' => true }
    end
    before = snapshot
    expect(cli_body('features')['features'].map { |f| f['name'] }).to eq(['chat'])
    state = cli_body('show', 'chat')['feature']
    expect(state).to include('percentage' => 25.5, 'users' => ['10', '2'], 'groups' => ['all', 'staff'],
      'data' => { 'nested' => { 'value' => nil }, 'enabled' => true })
    expect(cli_body('history', 'chat', '--since', '2000-01-01')['events'].length).to eq(2)
    expect(cli_body('history', '--since', '24h')['events'].length).to eq(2)
    expect(snapshot).to eq(before)
  end

  it 'round trips encoded names without confusing routes or decoding twice' do
    names = ['space name', 'percent%2F', 'slash/name', 'Zażółć', '.', '..', 'a+b', 'history']
    names.each { |name| change(name, 10) }
    names.each { |name| expect(cli_body('show', name)['feature']['name']).to eq(name) }
    expect(cli_body('features', '--limit', '2')['meta']).to eq('limit' => 2, 'truncated' => true)
    expect(cli_body('features')['features'].map { |f| f['name'] }).to eq(names.sort_by(&:b))
  end

  it 'maps missing features and host authentication failures to CLI exits' do
    before = snapshot
    [['missing', 4, 'integration-test'], ['missing', 3, 'invalid']].each do |name, code, token|
      stdout, stderr, status = cli('show', name, token: token)
      expect(stdout).to eq('')
      expect(status.exitstatus).to eq(code)
      expect(stderr).not_to include(token)
    end
    expect(snapshot).to eq(before)
  end

  it 'keeps independent count retention and preserves global events after deletion' do
    change('quiet', 10)
    4.times { |i| change('busy', i + 1) }
    expect(body('/features/quiet/history')['events'].length).to eq(1)
    expect(body('/history')['events'].map { |e| e['feature'] }).to eq(['busy'] * 3)
    expect(body('/features/busy/history')['events'].map { |e| e['data']['after']['percentage'] }).to eq([4, 3, 2])
    @rollout.delete('busy')
    expect(request('/features/busy/history').first).to eq(404)
    expect(cli_body('history')['events'].length).to eq(3)
    change('busy', 50)
    expect(cli_body('history', 'busy')['events'].length).to eq(1)
    expect(cli_body('history')['events'].map { |e| e['data']['after']['percentage'] }).to eq([50, 4, 3])
  end

  it 'uses inclusive timestamps, descending id ties and N+1 truncation' do
    time = Time.utc(2026, 9, 30, 12, 0, 0, 123456)
    allow(Time).to receive(:now).and_return(time)
    [10, 20, 30].each { |value| change('chat', value) }
    data = cli_body('history', 'chat', '--since', time.iso8601(6), '--limit', '2')
    expect(data['events'].map { |e| e['data']['after']['percentage'] }).to eq([30, 20])
    expect(data['meta']).to include('truncated' => true, 'since' => time.iso8601(6))
    expect(data['events'].first['context']).to eq('actor' => 'employee', 'nullable' => nil)
    expect(cli_body('history', '--since', (time + 1).iso8601)['events']).to eq([])
    expect(body('/history?since=2000-01-01T01:00:00%2B01:00')['meta']['since']).to eq('2000-01-01T00:00:00.000000Z')
  end

  it 'reads only N+1 newest records and filters before determining truncation' do
    times = [Time.utc(2026, 1, 1), Time.utc(2026, 1, 2), Time.utc(2026, 1, 3)]
    times.each_with_index do |time, i|
      allow(Time).to receive(:now).and_return(time)
      change('chat', (i + 1) * 10)
    end
    expect(@adapter).to receive(:global_events).with(limit: 3).and_call_original
    data = body('/history?limit=2&since=2026-01-02T00:00:00Z')
    expect(data['events'].length).to eq(2)
    expect(data['meta']['truncated']).to eq(false)
    expect(@adapter).to receive(:feature_events).with('chat', limit: 2).and_call_original
    expect(body('/features/chat/history?limit=1')['meta']['truncated']).to eq(true)
  end

  it 'exposes the shared adapter state without evaluating randomized decisions' do
    randomized = Rollout.new(adapter: @adapter, randomize_percentage: true,
      logging: { history_length: 3, global: true })
    randomized.activate_percentage('shared', 25)
    expect(cli_body('show', 'shared')['feature']['percentage']).to eq(25)
    expect(cli_body('history')['events'].first['feature']).to eq('shared')
  end

  it 'keeps empty and disabled feature history distinct' do
    expect(body('/history')['meta']['retention']['enabled']).to eq(true)
    @rollout.logging.without { @rollout.activate('empty') }
    expect(body('/features/empty/history')['events']).to eq([])
    rollout = Rollout.new(adapter: @adapter, logging: { global: false })
    rollout.activate('logged')
    @api = described_class.new(instance: rollout, environment: 'test')
    expect(body('/features/logged/history')['events'].length).to eq(1)
    expect(body('/history')['meta']['retention']['enabled']).to eq(false)
    @api = described_class.new(instance: Rollout.new(adapter: @adapter), environment: 'test')
    expect(body('/features/logged/history')['meta']['retention']).to include('enabled' => false, 'max_events' => nil)
  end

  it 'reports unknown completeness independently of truncation' do
    change('chat', 10)
    meta = body('/history?since=2000-01-01T00:00:00Z')['meta']
    expect(meta['truncated']).to eq(false)
    expect(meta['retention']).to eq('enabled' => true, 'max_events' => 3,
      'oldest_available_at' => nil, 'completeness' => 'unknown', 'deletion_events' => false)
  end

  it 'supports disabled logging, disabled global logging and zero retention' do
    [false, { history_length: 3, global: false }, { history_length: 0, global: true }].each do |logging|
      rollout = Rollout.new(adapter: @adapter, logging: logging)
      rollout.activate('chat')
      @api = described_class.new(instance: rollout, environment: 'test')
      data = body('/history')
      expect(data['events']).to eq([])
      expect(data['meta']['retention']['enabled']).to eq(logging.is_a?(Hash) && logging[:global])
      expect(data['meta']['truncated']).to eq(false)
    end
  end

  it 'returns a service error for unsupported history instead of fabricated empty results' do
    allow(@adapter).to receive(:global_events).and_raise(NotImplementedError)
    expect(request('/history').first).to eq(503)
  end

  it 'rejects oversized results and does not leak storage errors' do
    @rollout.with_feature('large') { |f| f.data = { 'text' => 'x' * described_class::MAX_BYTES } }
    expect(request('/features/large').first).to eq(413)
    allow(@adapter).to receive(:feature_exists?).and_raise('private database credentials')
    status, data = request('/features/large')
    expect(status).to eq(503)
    expect(data.to_s).not_to include('credentials')
  end

  it 'does not synthesize state when a feature disappears during a read' do
    change('chat', 10)
    allow(@adapter).to receive(:feature_exists?).with('chat').and_return(true, true, false)
    expect(request('/features/chat').first).to eq(503)
  end

  it 'rejects mutation methods without changing storage' do
    change('chat', 10)
    before = snapshot
    %w[POST PUT PATCH DELETE HEAD OPTIONS].each do |method|
      status, _, headers = request('/features/chat', method: method)
      expect(status).to eq(405)
      expect(headers['allow']).to eq('GET')
    end
    expect(snapshot).to eq(before)
  end

  it 'rejects invalid, duplicate and unknown parameters and invalid UTF-8 names' do
    paths = ['/features?limit=0', '/features?limit=1001', '/features?limit=-1', '/features?limit=1.0',
      '/features?limit=1&limit=2', '/features?%6cimit=1&limit=2', '/features?unknown=x',
      '/features?limit[]=1', '/features?limit=%zz', '/features?since=2026-01-01',
      '/history?since=2026-02-30T00:00:00Z', '/history?since=2026-01-01',
      '/history?since=2026-01-01T25:00:00Z', '/history?since=2026-01-01T00:00:00%2B99:00',
      '/features/%FF', '/features/%00', '/features/%zz', '/features/' + ('a' * 257),
      '/history?x=' + ('x' * 1024)]
    paths.each { |path| expect(request(path).first).to eq(400), path }
    expect(request('/other').first).to eq(404)
  end
end
