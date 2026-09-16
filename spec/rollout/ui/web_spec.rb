require 'spec_helper'
require 'cgi'

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
    let(:rollout) { Rollout.new(adapter: Rollout::Adapters::Redis.new(REDIS), logging: { global: true }) }
    let(:feature_name) { :history_feature_for_rollout_ui_webspec }

    around do |example|
      previous_instance = Rollout::UI.config.get(:instance)
      history_instance = rollout
      REDIS.del('feature:_global_:logging:events')
      Rollout::UI.configure { instance { history_instance } }
      example.run
    ensure
      Rollout::UI.configure { instance { previous_instance } }
      rollout.delete(feature_name)
      REDIS.del('feature:_global_:logging:events', "feature:#{feature_name}:logging:events")
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

      allow(rollout).to receive(:get).and_call_original
      expect { get '/' }.not_to change { rollout.features }

      expect(last_response).to be_ok
      expect(rollout).not_to have_received(:get).with(satisfy { |name| name.to_s == feature_name.to_s })
      history = last_response.body.split('History</h2>', 2).fetch(1)
      expect(history).to match(%r{<td\b[^>]*>\s*#{feature_name}\s*</td>})
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
        expect(history).to match(%r{<td\b[^>]*>\s*&lt;script&gt;alert\(42\)&lt;/script&gt;\s*</td>})
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

  it "escapes markup in the action index" do
    ROLLOUT.activate(:'<script>alert(1)</script>')

    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    expect(last_response.body).not_to include('<script>alert(1)</script>', '&amp;lt;script')
  end

  it "renders show html" do
    get '/features/test'

    expect(last_response).to be_ok
    expect(last_response.body).to include('Rollout UI') & include('test')
  end

  it "escapes javascript in the action show" do
    get "/features/'+alert(1)+'"

    expect(last_response).to be_ok
    expect(last_response.body).to include('&#39;+alert(1)+&#39;')
    expect(last_response.body).not_to include('&amp;#39;')
  end

  context 'ERB rendering' do
    let(:name) { %q{quotes'"\\ & <script>alert(1)</script>} }
    let(:description) { %q{A "description" & <img src=x onerror=alert(1)>} }
    let(:group) { %q{group'"<&>} }
    let(:users) { ['</textarea><script>alert(1)</script>'] }
    let(:feature) do
      double('feature', name: name, percentage: 25.5, groups: [group.to_sym], users: users,
             data: { 'description' => description, 'updated_at' => 123 })
    end
    let(:rollout) { double('rollout', features: [name], get: feature, groups: [group.to_sym, :other]) }

    before do
      allow(Rollout::UI.config).to receive(:get).and_call_original
      allow(Rollout::UI.config).to receive(:get).with(:instance).and_return(rollout)
    end

    it 'escapes text and attributes on the index and keeps confirmation messages intact' do
      get '/'

      expect(last_response).to be_ok
      [name, description, group].each do |value|
        expect(last_response.body).to include(CGI.escapeHTML(value))
        expect(last_response.body).not_to include(value)
      end
      messages = last_response.body.scan(/onclick="return confirm\((.*?)\)"/).flatten.map do |value|
        JSON.parse(CGI.unescapeHTML(value))
      end
      expect(messages).to eq([
        "Are you sure you want activate #{name} to 100%?",
        "Are you sure you want activate #{name} to 0%?",
        "Are you sure you want to delete #{name}?"
      ])
      expect(last_response.body.scan('<!DOCTYPE html>').size).to eq(1)
    end

    it 'preserves escaped form values, selected groups, errors, and the delete confirmation' do
      get '/features/test', error: '<script>bad()</script>'

      expect(last_response).to be_ok
      expect(last_response.body).to include("value=\"#{CGI.escapeHTML(description)}\"")
      expect(last_response.body).to include("value=\"#{CGI.escapeHTML(group)}\" selected>")
      expect(last_response.body).to include('value="other">', 'value="">(none)')
      expect(last_response.body).to include('name="last_updated_at" value="123"', 'form="updateFormSubmit"')
      expect(last_response.body).to include("rows=\"2\">#{CGI.escapeHTML(users.join(', '))}</textarea>")
      expect(last_response.body).to include('&lt;script&gt;bad()&lt;/script&gt;')
      expect(last_response.body).not_to include(description, users.first, '<script>bad()</script>')
      message = last_response.body[/onclick="return confirm\((.*?)\)"/, 1]
      expect(JSON.parse(CGI.unescapeHTML(message))).to eq("Are you sure you want to delete #{name}?")
    end

    it 'selects none for empty groups and hides the users field above 150 users' do
      allow(feature).to receive(:groups).and_return([])
      allow(feature).to receive(:users).and_return((1..151).to_a)

      get '/features/test'

      expect(last_response).to be_ok
      expect(last_response.body).to include('value="" selected>(none)', '>151</div>')
      expect(last_response.body).not_to include('<textarea', 'value="other" selected')
    end

    it 'renders the new form and retains mounted links and stylesheet paths' do
      get '/features/new', {}, 'SCRIPT_NAME' => '/rollout'

      expect(last_response).to be_ok
      expect(last_response.body).to include('href="/rollout/"', 'href="/rollout/css/tailwind.min.css"')
      expect(last_response.body).to include('action="/rollout/features/new" method="POST"', 'name="name"')
      expect(last_response.body).to include('id="theme-toggle"', "localStorage.getItem('theme')")
    end

    it 'renders escaped history in the index and show pages without nesting layouts' do
      actor = '<actor & "name">'
      event = double('event', name: 'update', feature: name, context: { actor: actor },
                     data: { before: { 'data.description' => nil }, after: { 'data.description' => description } },
                     created_at: Time.now)
      logging = double('logging', global_events: [event], events: [event], updated_at: Time.now)
      allow(rollout).to receive(:logging).and_return(logging)
      allow(Rollout::UI.config).to receive(:defined?).with(:actor_url).and_return(true)
      allow(Rollout::UI.config).to receive(:get).with(:actor_url, actor).and_return('/actors?id=1&view="full"')

      ['/', '/features/test'].each do |path|
        get path

        expect(last_response).to be_ok
        expect(last_response.body.scan('<!DOCTYPE html>').size).to eq(1)
        expect(last_response.body.scan('>History</h2>').size).to eq(1)
        expect(last_response.body).to include(CGI.escapeHTML(actor), CGI.escapeHTML(description))
        expect(last_response.body).to include('href="/actors?id=1&amp;view=&quot;full&quot;"')
        expect(last_response.body.gsub(/\s+/, ' ')).to include('changed description from &#39;&#39; to')
        expect(last_response.body).not_to include(actor, description)
        expect(last_response.body.include?('>Feature</th>')).to eq(path == '/')
      end
    end

    it 'escapes non-update history and handles an unidentified actor with no changes' do
      events = [
        double('event', name: 'delete', feature: name, data: '<script>history()</script>', created_at: Time.now),
        double('event', name: 'update', feature: name, context: nil,
               data: { before: { 'data.updated_at' => 1 }, after: { 'data.updated_at' => 2 } }, created_at: Time.now)
      ]
      allow(rollout).to receive(:logging).and_return(double('logging', events: events))

      get '/features/test'

      expect(last_response).to be_ok
      expect(last_response.body).to include('&lt;script&gt;history()&lt;/script&gt;')
      expect(last_response.body).not_to include('<script>history()</script>')
      expect(last_response.body.gsub(/\s+/, ' ')).to include('unidentified user changed nothing!')
    end
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

  it "exposes timestamps as ISO-8601 data attributes and a timezone toggle" do
    ROLLOUT.activate(:tz_feature_for_rollout_ui_webspec)

    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).to include('id="timezone-toggle"', 'Time: Local', 'Theme: System')
    expect(last_response.body).to include('data-timestamp-format="%Y-%m-%d %H:%M %Z"')
    expect(last_response.body).to match(/data-timestamp="\d{4}-\d{2}-\d{2}T[^"]+"/)

    get '/features/tz_feature_for_rollout_ui_webspec'

    expect(last_response).to be_ok
    expect(last_response.body).to include('id="timezone-toggle"', 'Time: Local', 'Theme: System')
    expect(last_response.body).to include('data-timestamp-format="%Y-%m-%d %H:%M %Z"')
    expect(last_response.body).to match(/data-timestamp="\d{4}-\d{2}-\d{2}T[^"]+"/)
  ensure
    ROLLOUT.delete(:tz_feature_for_rollout_ui_webspec)
  end
end
