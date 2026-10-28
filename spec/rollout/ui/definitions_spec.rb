require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Missing feature definitions' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.new
  end

  def feature_row
    last_response.body.split('</tr>').find { |row| row.include?(%{href="/features/#{feature_name}"}) }
  end

  let(:config) { Rollout::UI::Config.new }
  let(:feature_name) { :definition_ui_spec }

  before do
    config.instance { ROLLOUT }
    allow(Rollout::UI).to receive(:config).and_return(config)
    ROLLOUT.deactivate(feature_name)
  end

  after { ROLLOUT.delete(feature_name) }

  it 'marks missing definitions on the overview and feature page without changing stored state' do
    config.defined_features { [] }

    ['/', "/features/#{feature_name}"].each do |path|
      expect { get path }.not_to change { ROLLOUT.get(feature_name).to_hash }

      expect(last_response).to be_ok
      expect(last_response.body).to include('Missing definition')
    end
  end

  it 'accepts string and symbol names supplied by the application' do
    [feature_name, feature_name.to_s].each do |name|
      config.defined_features { [name] }

      get '/'

      expect(last_response).to be_ok
      expect(feature_row).not_to include('Missing definition')

      get "/features/#{feature_name}"

      expect(last_response).to be_ok
      expect(last_response.body).not_to include('Missing definition')
    end
  end

  it 'keeps missing definitions visible in the overview when logging is disabled' do
    silent = Rollout.new(adapter: Rollout::Adapters::Redis.new(REDIS))
    config.instance { silent }
    config.defined_features { [] }

    get '/'

    expect(last_response).to be_ok
    expect(feature_row).to include('Missing definition')
  end

  it 'disables checking when the callback returns nil' do
    config.defined_features { nil }

    get "/features/#{feature_name}"

    expect(last_response).to be_ok
    expect(last_response.body).not_to include('Missing definition')
  end

  it 'loads names once per HTML request and refreshes them on the next request' do
    calls = 0
    names = []
    config.defined_features { calls += 1; names }

    get '/'

    expect(feature_row).to include('Missing definition')
    expect(calls).to eq(1)

    names << feature_name
    get '/'

    expect(feature_row).not_to include('Missing definition')
    expect(calls).to eq(2)
  end

  it 'does not load definitions or change JSON responses' do
    config.defined_features { raise 'must not load definitions for JSON' }
    header 'Accept', 'application/json'

    get "/features/#{feature_name}"

    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)).to eq(
      'name' => feature_name.to_s, 'percentage' => 0.0, 'groups' => [], 'data' => {}
    )

    get '/'

    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)).to include('name' => feature_name.to_s, 'percentage' => 0.0, 'groups' => [], 'data' => {})
  end

  it 'does not report definition-loading errors as missing definitions' do
    config.defined_features { raise ArgumentError, 'invalid definition' }

    expect { get '/' }.to raise_error(ArgumentError, 'invalid definition')
  end

  it 'leaves checking disabled on older Rollout versions' do
    allow(Rollout).to receive(:respond_to?).and_call_original
    allow(Rollout).to receive(:respond_to?).with(:definitions).and_return(false)

    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).not_to include('Missing definition')
  end

  context 'with Rollout definitions support' do
    around do |example|
      Dir.mktmpdir do |dir|
        @definitions_dir = dir
        example.run
      end
    end

    before do
      allow(Rollout).to receive(:definitions_path).and_return(@definitions_dir)
      allow(Rollout).to receive(:definitions).and_return({})
    end

    it 'uses definitions from Rollout by default, including an empty directory' do
      get '/'

      expect(feature_row).to include('Missing definition')

      allow(Rollout).to receive(:definitions).and_return(feature_name => Object.new)
      get '/'

      expect(feature_row).not_to include('Missing definition')
    end

    it 'disables checking when the path is missing or nil' do
      [File.join(Rollout.definitions_path, 'missing'), nil].each do |path|
        allow(Rollout).to receive(:definitions_path).and_return(path)
        expect(Rollout).not_to receive(:definitions)

        get '/'

        expect(last_response).to be_ok
        expect(last_response.body).not_to include('Missing definition')
      end
    end

    it 'lets the application callback override YAML-only definitions' do
      config.defined_features { [feature_name] }
      expect(Rollout).not_to receive(:definitions)

      get '/'

      expect(feature_row).not_to include('Missing definition')
    end

    it 'preserves errors from the default definitions loader' do
      allow(Rollout).to receive(:definitions).and_raise(ArgumentError, 'invalid YAML')

      expect { get '/' }.to raise_error(ArgumentError, 'invalid YAML')
    end
  end
end
