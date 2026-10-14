require "spec_helper"

RSpec.describe Rollout::UI::Helpers do
  subject(:helpers) do
    Class.new { include Rollout::UI::Helpers }.new
  end

  it "returns empty markup when time is missing" do
    expect(helpers.relative_timestamp_tag(nil)).to eq("")
  end

  it "renders an ISO-8601 timestamp for client-side timezone conversion" do
    time = Time.new(2026, 9, 10, 11, 7, 28, "+02:00")

    html = helpers.relative_timestamp_tag(time)

    expect(html).to include(%(data-timestamp="#{time.iso8601}"))
    expect(html).to include(%(title="#{time.strftime("%Y-%m-%d %H:%M %Z")}"))
    expect(html).to include(helpers.time_ago(time))
  end

  it "uses the configured timestamp_format in the fallback title" do
    time = Time.utc(2026, 9, 10, 9, 7, 0)
    allow(helpers).to receive(:config).and_return(double(get: "%d/%m/%Y %H:%M %Z"))

    html = helpers.relative_timestamp_tag(time)

    expect(html).to include(%(title="#{time.strftime("%d/%m/%Y %H:%M %Z")}"))
  end

  describe "feature versions" do
    let(:feature) do
      double("feature", name: "chat", percentage: 25.0, groups: [:employees, :developers],
        users: %w[123 456], data: { "description" => "Chat dock", "updated_at" => 1 })
    end

    it "returns a stable SHA-256 fingerprint" do
      version = helpers.feature_version(feature)

      expect(version).to match(/\A[0-9a-f]{64}\z/)
      expect(helpers.feature_version(feature)).to eq(version)
    end

    it "ignores ordering and equivalent user ID, group, and percentage representations" do
      version = helpers.feature_version(feature)
      allow(feature).to receive(:users).and_return([456, 123])
      allow(feature).to receive(:groups).and_return(%w[developers employees])
      allow(feature).to receive(:percentage).and_return(25)

      expect(helpers.feature_version(feature)).to eq(version)
    end

    it "ignores timestamps and metadata that the form does not edit" do
      version = helpers.feature_version(feature)
      feature.data["updated_at"] = 2
      feature.data["other"] = "metadata"

      expect(helpers.feature_version(feature)).to eq(version)
    end

    it "treats nil and empty descriptions as equivalent" do
      feature.data["description"] = nil
      version = helpers.feature_version(feature)
      feature.data["description"] = ""

      expect(helpers.feature_version(feature)).to eq(version)
    end

    { name: "other", percentage: 50.0, groups: [:employees], users: %w[123] }.each do |field, value|
      it "changes when #{field} changes" do
        version = helpers.feature_version(feature)
        allow(feature).to receive(field).and_return(value)

        expect(helpers.feature_version(feature)).not_to eq(version)
      end
    end

    it "changes when the description changes" do
      version = helpers.feature_version(feature)
      feature.data["description"] = "Updated chat dock"

      expect(helpers.feature_version(feature)).not_to eq(version)
    end
  end
end
