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
end
