require 'rails_helper'
require 'csv'

RSpec.describe 'Conversation heatmap CSV date range', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:headers) { admin.create_new_auth_token }
  let(:csv_path) { "/api/v2/accounts/#{account.id}/reports/conversation_traffic.csv" }
  let(:chart_params) do
    {
      metric: 'conversations_count', type: 'account', group_by: 'hour', business_hours: false,
      since: Time.utc(2026, 9, 12).to_i.to_s, until: Time.utc(2026, 9, 18, 23, 59, 59).to_i.to_s, timezone_offset: 0
    }
  end

  around do |example|
    with_modified_env TZ: 'UTC' do
      Time.use_zone('UTC') { travel_to(Time.utc(2026, 9, 18, 12)) { example.run } }
    end
  end

  before do
    # A numeric zero otherwise resolves to a region that observes daylight saving time.
    utc = ActiveSupport::TimeZone['UTC']
    allow(ActiveSupport::TimeZone).to receive(:[]).and_call_original
    allow(ActiveSupport::TimeZone).to receive(:[]).with(0).and_return(utc)
  end

  it 'exports the same seven dates and current-day counts as the default chart' do
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 12, 12))
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 18, 10))
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 11, 23, 59, 59))
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 19))
    create(:conversation, created_at: Time.utc(2026, 9, 18, 10))

    get "/api/v2/accounts/#{account.id}/reports", params: chart_params, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    chart_total = response.parsed_body.sum { |row| row.fetch('value') }
    expect(chart_total).to eq(2)

    get csv_path, params: { days_before: 6, timezone_offset: 0 }, headers: headers
    expect(response).to have_http_status(:success)
    csv = CSV.parse(response.body)
    date_header = csv.find { |row| row.first == 'Start of the hour' }
    hour_rows = csv.select { |row| row.first.to_s.match?(/\A\d{2}:00\z/) }

    expect(date_header).to eq(['Start of the hour'] + (12..18).map { |day| "2026-09-#{day}" })
    expect(hour_rows.map { |row| [row.first, row.size] }).to eq((0..23).map { |hour| [format('%02d:00', hour), 8] })
    expect(hour_rows.sum { |row| row.drop(1).sum(&:to_i) }).to eq(chart_total)
    expect(hour_rows.find { |row| row.first == '10:00' }.last.to_i).to eq(1)
  end

  it 'defaults to the same date range when days_before is omitted' do
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 18, 10))

    get csv_path, params: { days_before: 6, timezone_offset: 0 }, headers: headers
    expect(response).to have_http_status(:success)
    csv = CSV.parse(response.body)

    get csv_path, params: { timezone_offset: 0 }, headers: headers
    expect(response).to have_http_status(:success)
    expect(CSV.parse(response.body)).to eq(csv)
  end

  it 'retains both eligible conversations when all activity is historical' do
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 12, 12))
    create(:conversation, account: account, inbox: inbox, created_at: Time.utc(2026, 9, 17, 12))

    get "/api/v2/accounts/#{account.id}/reports", params: chart_params, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body.sum { |row| row.fetch('value') }).to eq(2)

    get csv_path, params: { days_before: 6, timezone_offset: 0 }, headers: headers
    expect(response).to have_http_status(:success)
    hour_rows = CSV.parse(response.body).select { |row| row.first.to_s.match?(/\A\d{2}:00\z/) }
    expect(hour_rows.sum { |row| row.drop(1).sum(&:to_i) }).to eq(2)
  end
end
