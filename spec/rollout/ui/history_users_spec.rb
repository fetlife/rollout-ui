require 'spec_helper'
require 'cgi'

RSpec.describe 'Nicknames in feature history' do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.new
  end

  let(:config) { Rollout::UI::Config.new }
  let(:lookup) do
    ->(ids) { ids.filter_map { |id| { id: id, nickname: nicknames[id] } if nicknames.key?(id) } }
  end
  let(:nicknames) { { '1' => 'alice', '19' => 'bob' } }
  let(:before_values) { { users: [], 'data.description' => nil } }
  let(:after_values) { { users: ['1', '19'], 'data.description' => '' } }
  let(:event) do
    double('event', name: 'update', feature: 'test', created_at: Time.now, context: nil,
      data: { before: before_values, after: after_values })
  end
  let(:feature) { double('feature', name: 'test', users: [], groups: [], percentage: 0, data: {}) }
  let(:logging) { double('logging', events: [event], global_events: [event], updated_at: nil) }
  let(:rollout) { double('rollout', features: ['test'], get: feature, groups: [], logging: logging) }

  before do
    config.instance { rollout }
    config.user_lookup(&lookup)
    allow(Rollout::UI).to receive(:config).and_return(config)
  end

  it 'renders nicknames in both feature and overview history without an empty description change' do
    expect(lookup).to receive(:call).twice.with(['1', '19']).and_call_original

    ['/', '/features/test'].each do |path|
      get path

      expect(last_response).to be_ok
      expect(last_response.body).to include('unidentified user changed users from [] to [alice, bob]')
      expect(last_response.body).not_to include('users from [] to [1, 19]', "description from &#39;&#39; to &#39;&#39;")
    end
    expect(event.data[:after][:users]).to eq(['1', '19'])
  end

  it 'resolves removed users as well as added users and deduplicates IDs across events' do
    before_values[:users] = ['1']
    after_values[:users] = ['19']
    allow(logging).to receive(:global_events).and_return([event, event])
    expect(lookup).to receive(:call).once.with(['1', '19']).and_call_original

    get '/'

    expect(last_response.body).to include('users from [alice] to [bob]')
  end

  it 'reuses selected-user lookups and only fetches missing history IDs' do
    config.user_search { [] }
    allow(feature).to receive(:users).and_return(['19'])
    expect(lookup).to receive(:call).once.with(['19']).and_call_original
    expect(lookup).to receive(:call).once.with(['1']).and_call_original

    get '/features/test'

    expect(last_response.body).to include('data-user-id="19" data-nickname="bob"', 'users from [] to [alice, bob]')
  end

  it 'escapes nicknames in history' do
    nicknames['1'] = '<script>alert("history")</script>'
    get '/features/test'

    expect(last_response.body).to include(CGI.escapeHTML(nicknames['1']))
    expect(last_response.body).not_to include(nicknames['1'])
  end

  it 'preserves IDs for accounts that cannot be resolved' do
    nicknames.delete('19')
    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('users from [] to [alice, Unknown user (#19)]')
  end

  it 'keeps history readable when the lookup fails' do
    allow(lookup).to receive(:call).and_raise('directory unavailable')
    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('users from [] to [Unknown user (#1), Unknown user (#19)]')
    expect(last_response.body).not_to include('directory unavailable')
  end

  it 'does not retry unresolved selected IDs when rendering history' do
    config.user_search { [] }
    allow(feature).to receive(:users).and_return(['1', '19'])
    nicknames.delete('19')
    expect(lookup).to receive(:call).once.with(['1', '19']).and_call_original

    get '/features/test'

    expect(last_response.body).to include('users from [] to [alice, Unknown user (#19)]')
  end

  it 'caps a page of history at 150 distinct IDs even when an event contains more users' do
    after_values[:users] = (1..200).to_a
    expect(lookup).to receive(:call).once.with((1..150).map(&:to_s)).and_call_original

    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('User (#151)', 'User (#200)')
    expect(last_response.body).not_to include('Unknown user (#151)', 'Unknown user (#200)')
  end

  it 'leaves group arrays unchanged and skips unchanged fields' do
    before_values[:groups] = []
    after_values[:groups] = [1, 19]
    before_values[:percentage] = after_values[:percentage] = 0
    get '/features/test'

    expect(last_response.body).to include('groups from [] to [1, 19]')
    expect(last_response.body).not_to include('percentage from 0 to 0')
  end

  it 'retains raw IDs when nickname lookup is not configured' do
    plain_config = Rollout::UI::Config.new
    plain_config.instance { rollout }
    allow(Rollout::UI).to receive(:config).and_return(plain_config)
    expect(lookup).not_to receive(:call)

    get '/features/test'

    expect(last_response.body).to include('users from [] to [1, 19]')
  end

  it 'does not query the user directory for events without user changes' do
    before_values.delete(:users)
    after_values.delete(:users)
    expect(lookup).not_to receive(:call)
    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('changed nothing!')
  end
end
