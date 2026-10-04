require 'rails_helper'

RSpec.describe 'Applied SLAs API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent1) { create(:user, account: account, role: :agent) }
  let(:agent2) { create(:user, account: account, role: :agent) }
  let(:conversation1) { create(:conversation, account: account, assignee: agent1) }
  let(:conversation2) { create(:conversation, account: account, assignee: agent2) }
  let(:conversation3) { create(:conversation, account: account, assignee: agent2) }
  let(:sla_policy1) { create(:sla_policy, account: account) }
  let(:sla_policy2) { create(:sla_policy, account: account) }

  before do
    account.enable_features!('sla')
    AppliedSla.destroy_all
  end

  describe 'exact label filtering across SLA reports' do
    let(:headers) { administrator.create_new_auth_token }
    let(:window_start) { Time.utc(2026, 9, 17) }
    let(:date_params) { { since: window_start.to_i.to_s, until: (window_start + 1.day).to_i.to_s, timezone_offset: 0 } }

    before do
      conversation1.update_labels('vip')
      conversation2.update_labels('vip-followup')
      create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: :hit, created_at: window_start + 12.hours)
      create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: :missed, created_at: window_start + 12.hours)
    end

    [
      ['vip', 1, 0, '100%'],
      ['vip-followup', 1, 1, '0.0%'],
      [nil, 2, 1, '50.0%']
    ].each do |label, total, misses, hit_rate|
      context "with label filter #{label.inspect}" do
        let(:params) { date_params.merge(label_list: label) }

        it 'returns metrics for the selected cohort' do
          get "/api/v1/accounts/#{account.id}/applied_slas/metrics", params: params, headers: headers

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to include('total_applied_slas' => total, 'number_of_sla_misses' => misses, 'hit_rate' => hit_rate)
        end

        it 'returns only the selected breached conversations' do
          get "/api/v1/accounts/#{account.id}/applied_slas", params: params, headers: headers

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body['meta']['count']).to eq(misses)
          expected_ids = misses.zero? ? [] : [conversation2.display_id]
          expect(response.parsed_body['payload'].map { |row| row.dig('conversation', 'id') }).to match_array(expected_ids)
        end

        it 'exports only the selected breached conversations' do
          get "/api/v1/accounts/#{account.id}/applied_slas/download", params: params, headers: headers

          expect(response).to have_http_status(:ok)
          rows = CSV.parse(response.body).reject { |row| row.all?(&:nil?) }.drop(1)
          expected_ids = misses.zero? ? [] : [conversation2.display_id]
          expect(rows.map { |row| row[0].to_i }).to match_array(expected_ids)
        end
      end
    end

    context 'when a matching breached conversation has additional labels' do
      before do
        conversation3.update_labels(%w[vip urgent])
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation3, sla_status: :missed, created_at: window_start + 12.hours)
      end

      it 'includes it exactly once in metrics, breach rows and CSV' do
        params = date_params.merge(label_list: 'vip')
        get "/api/v1/accounts/#{account.id}/applied_slas/metrics", params: params, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('total_applied_slas' => 2, 'number_of_sla_misses' => 1, 'hit_rate' => '50.0%')

        get "/api/v1/accounts/#{account.id}/applied_slas", params: params, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['meta']['count']).to eq(1)
        expect(response.parsed_body['payload'].map { |row| row.dig('conversation', 'id') }).to contain_exactly(conversation3.display_id)

        get "/api/v1/accounts/#{account.id}/applied_slas/download", params: params, headers: headers
        expect(response).to have_http_status(:ok)
        rows = CSV.parse(response.body).reject { |row| row.all?(&:nil?) }.drop(1)
        expect(rows.map { |row| row[0].to_i }).to contain_exactly(conversation3.display_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/applied_slas/metrics' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/applied_slas/metrics"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns the sla metrics' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 1)
        expect(body).to include('number_of_sla_misses' => 1)
        expect(body).to include('hit_rate' => '0.0%')
      end

      it 'excludes conversations with blocked contacts from metrics' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        conversation2.contact.update!(blocked: true)

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 1)
        expect(body).to include('number_of_sla_misses' => 1)
        expect(body).to include('hit_rate' => '0.0%')
      end

      it 'filters sla metrics based on a date range' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago)

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            params: { since: 5.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 1)
        expect(body).to include('number_of_sla_misses' => 0)
        expect(body).to include('hit_rate' => '100%')
      end

      it 'filters sla metrics based on a date range and agent ids' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation3, created_at: 3.days.ago)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            params: { agent_ids: [agent2.id] },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 3)
        expect(body).to include('number_of_sla_misses' => 1)
        expect(body).to include('hit_rate' => '66.67%')
      end

      it 'filters sla metrics based on sla policy ids' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy2, conversation: conversation2, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            params: { sla_policy_id: sla_policy1.id },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 2)
        expect(body).to include('number_of_sla_misses' => 1)
        expect(body).to include('hit_rate' => '50.0%')
      end

      it 'filters sla metrics based on labels' do
        conversation2.update_labels('label1')
        conversation3.update_labels('label1')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation3, created_at: 3.days.ago)

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            params: { label_list: 'label1' },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('total_applied_slas' => 2)
        expect(body).to include('number_of_sla_misses' => 1)
        expect(body).to include('hit_rate' => '50.0%')
      end
    end

    context 'when the sla feature is disabled' do
      it 'returns unauthorized' do
        account.disable_features!('sla')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas/metrics",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/applied_slas/download' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/applied_slas/download"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns a CSV file with breached conversations' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        conversation1.update(status: 'open')
        conversation2.update(status: 'resolved')

        get "/api/v1/accounts/#{account.id}/applied_slas/download",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(response.headers['Content-Type']).to eq('text/csv')
        expect(response.headers['Content-Disposition']).to include('attachment; filename=breached_conversation.csv')

        csv_data = CSV.parse(response.body)
        csv_data.reject! { |row| row.all?(&:nil?) }
        expect(csv_data.size).to eq(3)
        conversation_ids = csv_data.drop(1).map { |row| row[0].to_i }
        expect(conversation_ids).to contain_exactly(conversation1.display_id, conversation2.display_id)
      end

      it 'excludes conversations with blocked contacts from the CSV file' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        conversation2.contact.update!(blocked: true)

        get "/api/v1/accounts/#{account.id}/applied_slas/download",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        csv_data = CSV.parse(response.body)
        csv_data.reject! { |row| row.all?(&:nil?) }
        expect(csv_data.size).to eq(2)
        expect(csv_data[1][0].to_i).to eq(conversation1.display_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/applied_slas' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/applied_slas"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns the applied slas' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        get "/api/v1/accounts/#{account.id}/applied_slas",
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)
        expect(body['payload'].size).to eq(1)
        expect(body['payload'].first).to include('applied_sla')
        expect(body['payload'].first['conversation']['id']).to eq(conversation2.display_id)
        expect(body['meta']).to include('count' => 1)
      end

      it 'excludes conversations with blocked contacts' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, sla_status: 'missed')
        conversation2.contact.update!(blocked: true)

        get "/api/v1/accounts/#{account.id}/applied_slas",
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body['payload'].size).to eq(1)
        expect(body['payload'].first['conversation']['id']).to eq(conversation1.display_id)
        expect(body['meta']).to include('count' => 1)
      end

      it 'filters applied slas based on a date range' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas",
            params: { since: 5.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body['payload'].size).to eq(1)
      end

      it 'filters applied slas based on a date range and agent ids' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago)
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation3, created_at: 3.days.ago, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago, sla_status: 'active_with_misses')

        get "/api/v1/accounts/#{account.id}/applied_slas",
            params: { agent_ids: [agent2.id] },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body['payload'].size).to eq(2)
      end

      it 'filters applied slas based on sla policy ids' do
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2)
        create(:applied_sla, sla_policy: sla_policy2, conversation: conversation2, sla_status: 'active_with_misses')

        get "/api/v1/accounts/#{account.id}/applied_slas",
            params: { sla_policy_id: sla_policy1.id },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body['payload'].size).to eq(1)
      end

      it 'filters applied slas based on labels' do
        conversation2.update_labels('label1')
        conversation3.update_labels('label1')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation1, created_at: 10.days.ago, sla_status: 'active_with_misses')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation2, created_at: 3.days.ago, sla_status: 'missed')
        create(:applied_sla, sla_policy: sla_policy1, conversation: conversation3, created_at: 3.days.ago, sla_status: 'missed')

        get "/api/v1/accounts/#{account.id}/applied_slas",
            params: { label_list: 'label1' },
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body['payload'].size).to eq(2)
      end
    end
  end
end
