require "spec_helper"

ENV["APP_ENV"] = "test"

RSpec.describe "Web UI mutations" do
  include Rack::Test::Methods

  def app
    Rollout::UI::Web.tap do |app|
      app.set :host_authorization, skip: true
    end
  end

  def restore_instance
    Rollout::UI.configure do
      instance { ROLLOUT }
      actor { nil }
    end
  end

  after { restore_instance }

  it "persists a full feature edit" do
    post "/features/chat",
      percentage: "25",
      groups: ["employees"],
      users: "1, 2",
      description: "New navigation",
      last_updated_at: ""

    expect(last_response).to be_redirect

    feature = ROLLOUT.get("chat")
    expect(feature.percentage).to eq 25.0
    expect(feature.groups).to eq [:employees]
    expect(feature.users).to eq %w[1 2]
    expect(feature.data["description"]).to eq "New navigation"
    expect(feature.data["updated_at"]).to be_a(Integer)
  end

  it "records one combined history event with the configured actor" do
    Rollout::UI.configure do
      instance { ROLLOUT }
      actor { "alice" }
    end

    post "/features/chat",
      percentage: "25",
      groups: ["employees"],
      users: "123",
      description: "New navigation",
      last_updated_at: ""

    events = ROLLOUT.logging.events("chat")
    expect(events.count).to eq 1
    expect(events.first.context[:actor]).to eq "alice"
    expect(events.first.data[:after].keys).to include(:percentage, :groups, :users, :"data.description", :"data.updated_at")
  end

  it "updates state and history from a quick percentage change" do
    post "/features/chat/activate-percentage", percentage: "100"

    expect(last_response).to be_redirect
    expect(ROLLOUT.get("chat").percentage).to eq 100.0
    expect(ROLLOUT.logging.last_event("chat").data[:after][:percentage]).to eq 100
  end

  it "rejects a stale form submission without changing state or history" do
    post "/features/chat", percentage: "10", description: "first", last_updated_at: ""
    token = ROLLOUT.get("chat").data["updated_at"]
    events_before = ROLLOUT.logging.events("chat").count

    post "/features/chat",
      percentage: "20",
      description: "stale",
      last_updated_at: (token.to_i - 1).to_s

    expect(last_response).to be_redirect
    expect(last_response.location).to include("error=")
    expect(ROLLOUT.get("chat").percentage).to eq 10.0
    expect(ROLLOUT.get("chat").data["description"]).to eq "first"
    expect(ROLLOUT.logging.events("chat").count).to eq events_before
  end

  it "deletes a feature and its history when logging is enabled" do
    ROLLOUT.activate(:chat)
    post "/features/chat/delete"

    expect(last_response).to be_redirect
    expect(ROLLOUT.features).to eq []
    expect(ROLLOUT.logging.events("chat")).to eq []
    expect(ROLLOUT.logging.global_events).not_to eq []
  end

  it "keeps existing history when deleting without logging" do
    ROLLOUT.activate_percentage(:chat, 25)
    silent = Rollout.new(backend: Rollout::Redis::Backend.new(REDIS))
    Rollout::UI.configure { instance { silent } }

    post "/features/chat/delete"

    expect(ROLLOUT.exists?(:chat)).to be_falsey
    expect(ROLLOUT.logging.events("chat")).not_to eq []
  end

  it "renders newest history first with actor and before/after values" do
    Rollout::UI.configure do
      instance { ROLLOUT }
      actor { "alice" }
    end

    post "/features/chat", percentage: "10", description: "first", last_updated_at: ""
    post "/features/chat",
      percentage: "25",
      description: "second",
      last_updated_at: ROLLOUT.get("chat").data["updated_at"].to_s

    get "/features/chat"

    expect(last_response).to be_ok
    expect(last_response.body).to include("alice")
    expect(last_response.body.index("from 10.0 to 25.0")).to be < last_response.body.index("from 0.0 to 10.0")
  end

  it "continues to index, show, and edit when logging is disabled" do
    silent = Rollout.new(backend: Rollout::Redis::Backend.new(REDIS))
    Rollout::UI.configure { instance { silent } }

    get "/"
    expect(last_response).to be_ok

    post "/features/chat", percentage: "15", description: "no logs", last_updated_at: ""
    expect(last_response).to be_redirect

    get "/features/chat"
    expect(last_response).to be_ok
    expect(last_response.body).to include("chat")
    expect(silent.get("chat").percentage).to eq 15.0
    expect(silent.respond_to?(:logging)).to eq false
  end
end
