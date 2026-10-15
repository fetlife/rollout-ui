require "spec_helper"
require "uri"

RSpec.describe "Feature form versions" do
  include Rack::Test::Methods

  let(:feature_name) { "feature_versions_spec" }
  let(:path) { "/features/#{feature_name}" }
  let(:config) { Rollout::UI::Config.new }
  let(:conflict_message) do
    "This rollout changed since you opened it. Your update was not saved. Review the latest state and try again."
  end

  def app
    Rollout::UI::Web.new
  end

  def response_version
    version = last_response.body[/name="feature_version" value="([^"]+)"/, 1]
    expect(version).to match(/\A[0-9a-f]{64}\z/)
    version
  end

  def form_version
    get path
    expect(last_response).to be_ok
    response_version
  end

  def expect_conflict
    expect(last_response).to be_redirect
    query = URI.parse(last_response.location).query
    expect(Rack::Utils.parse_query(query)).to eq("error" => conflict_message)
  end

  before do
    config.instance { ROLLOUT }
    config.actor { "alice" }
    allow(Rollout::UI).to receive(:config).and_return(config)
    ROLLOUT.delete(feature_name)
  end

  after { ROLLOUT.delete(feature_name) }

  it "renders a version and prevents caching HTML, JSON, and HEAD feature responses" do
    form_version
    expect(last_response.headers["Cache-Control"]).to eq("no-store")

    get path, {}, "HTTP_ACCEPT" => "application/json"
    expect(last_response).to be_ok
    expect(last_response.headers["Cache-Control"]).to eq("no-store")

    head path
    expect(last_response).to be_ok
    expect(last_response.body).to eq("")
    expect(last_response.headers["Cache-Control"]).to eq("no-store")
  end

  it "allows consecutive additions through freshly rendered forms without JavaScript" do
    first_version = form_version
    post path, user_changes: "1", users_to_add: "123", percentage: "25", feature_version: first_version
    expect(last_response.location).to eq(path)

    follow_redirect!
    expect(last_response).to be_ok
    second_version = response_version
    expect(second_version).not_to eq(first_version)
    expect(last_response.body).to include('name="users_to_remove[]" value="123"', 'name="users_to_add"')

    post path, user_changes: "1", users_to_add: "456", percentage: "25", feature_version: second_version
    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456])
    expect(ROLLOUT.logging.events(feature_name).count).to eq(2)
    expect(ROLLOUT.logging.last_event(feature_name).context[:actor]).to eq("alice")
  end

  it "rejects a stale form even when both updates happen in the same second" do
    allow(Time).to receive(:now).and_return(Time.at(1_800_000_000))
    post path, users: "123", percentage: "25"
    version = form_version
    timestamp = ROLLOUT.get(feature_name).data["updated_at"]

    post path, users: "123, 456", percentage: "25", feature_version: version
    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).data["updated_at"]).to eq(timestamp)
    events_before = ROLLOUT.logging.events(feature_name).count

    post path, users: "123, 789", percentage: "50", feature_version: version,
      last_updated_at: timestamp.to_s

    expect_conflict
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456])
    expect(ROLLOUT.get(feature_name).percentage).to eq(25.0)
    expect(ROLLOUT.logging.events(feature_name).count).to eq(events_before)
    follow_redirect!
    expect(last_response.body).to include(conflict_message)
    expect(response_version).not_to eq(version)
  end

  {
    percentage: ->(feature) { feature.percentage = 50 },
    groups: ->(feature) { feature.groups = [:employees] },
    users: ->(feature) { feature.users = %w[456] },
    description: ->(feature) { feature.data["description"] = "Updated externally" }
  }.each do |field, change|
    it "rejects external #{field} changes even without an updated_at timestamp" do
      version = form_version
      ROLLOUT.with_feature(feature_name, &change)
      state_before = ROLLOUT.adapter.fetch_feature(feature_name)
      events_before = ROLLOUT.logging.events(feature_name).count

      post path, users: "123", percentage: "25", description: "Stale", feature_version: version

      expect_conflict
      state_after = ROLLOUT.adapter.fetch_feature(feature_name)
      expect(state_after.users).to eq(state_before.users)
      expect(state_after.groups).to eq(state_before.groups)
      expect(state_after.percentage).to eq(state_before.percentage)
      expect(state_after.data).to eq(state_before.data)
      expect(ROLLOUT.logging.events(feature_name).count).to eq(events_before)
    end
  end

  it "validates against the current mutation state without a separate get" do
    version = form_version
    ROLLOUT.activate_user(feature_name, "456")
    expect(ROLLOUT).not_to receive(:get)

    post path, users: "123", percentage: "25", feature_version: version

    expect_conflict
    expect(ROLLOUT.adapter.fetch_feature(feature_name).users).to eq(%w[456])
  end

  it "does not conflict when users and groups have only been reordered" do
    ROLLOUT.with_feature(feature_name) do |feature|
      feature.users = %w[456 123]
      feature.groups = [:employees, :developers]
    end
    version = form_version
    ROLLOUT.with_feature(feature_name) do |feature|
      feature.users = %w[123 456]
      feature.groups = [:developers, :employees]
    end

    post path, users: "123, 456, 789", groups: %w[employees developers], percentage: "25",
      feature_version: version

    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456 789])
  end

  it "uses the fingerprint instead of the legacy timestamp when both are submitted" do
    post path, users: "123", percentage: "25"
    version = form_version
    ROLLOUT.with_feature(feature_name) do |feature|
      feature.data["updated_at"] = 1
      feature.data["other"] = "metadata"
    end

    post path, users: "123, 456", percentage: "25", feature_version: version, last_updated_at: "0"

    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123 456])
    expect(ROLLOUT.get(feature_name).data["other"]).to eq("metadata")
  end

  ["", "invalid"].each do |version|
    it "rejects #{version.inspect} fingerprints without falling back to a matching legacy timestamp" do
      ROLLOUT.with_feature(feature_name) { |feature| feature.data["updated_at"] = 1 }

      post path, users: "123", feature_version: version, last_updated_at: "1"

      expect_conflict
      expect(ROLLOUT.get(feature_name).users).to eq([])
    end
  end

  it "does not create a missing feature when its submitted version is invalid" do
    post path, users: "123", feature_version: "invalid"

    expect_conflict
    expect(ROLLOUT.exists?(feature_name)).to be_falsey
    expect(ROLLOUT.logging.events(feature_name)).to eq([])
  end

  it "accepts legacy forms with a matching timestamp" do
    ROLLOUT.with_feature(feature_name) { |feature| feature.data["updated_at"] = 1 }

    post path, users: "123", percentage: "25", last_updated_at: "1"

    expect(last_response.location).to eq(path)
    expect(ROLLOUT.get(feature_name).users).to eq(%w[123])
  end

  it "checks legacy timestamps against mutation state rather than a stale get" do
    ROLLOUT.with_feature(feature_name) { |feature| feature.data["updated_at"] = 1 }
    stale_feature = ROLLOUT.get(feature_name)
    ROLLOUT.with_feature(feature_name) { |feature| feature.data["updated_at"] = 2 }
    allow(ROLLOUT).to receive(:get).with(feature_name).and_return(stale_feature)
    events_before = ROLLOUT.logging.events(feature_name).count

    post path, users: "123", last_updated_at: "1"

    expect_conflict
    expect(ROLLOUT.adapter.fetch_feature(feature_name).data["updated_at"]).to eq(2)
    expect(ROLLOUT.logging.events(feature_name).count).to eq(events_before)
  end

  it "rejects an existing timestamped feature when both version fields are missing" do
    ROLLOUT.with_feature(feature_name) { |feature| feature.data["updated_at"] = 1 }

    post path, users: "123", percentage: "25"

    expect_conflict
    expect(ROLLOUT.get(feature_name).users).to eq([])
  end

  it "supports version validation when logging is disabled" do
    silent = Rollout.new(adapter: Rollout::Adapters::Redis.new(REDIS))
    config.instance { silent }
    version = form_version

    post path, users: "123", percentage: "25", feature_version: version
    expect(last_response.location).to eq(path)
    post path, users: "456", percentage: "50", feature_version: version

    expect_conflict
    expect(silent.get(feature_name).users).to eq(%w[123])
  end

  it "keeps the mount prefix in conflict redirects" do
    mounted = Rack::MockRequest.new(Rack::URLMap.new("/admin/rollout" => app))
    response = mounted.post("/admin/rollout#{path}", params: { feature_version: "invalid" })

    expect(response).to be_redirect
    expect(URI.parse(response["location"]).path).to eq("/admin/rollout#{path}")
    expect(Rack::Utils.parse_query(URI.parse(response["location"]).query)).to eq("error" => conflict_message)
  end
end
