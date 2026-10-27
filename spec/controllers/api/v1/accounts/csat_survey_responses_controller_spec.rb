require 'rails_helper'

RSpec.describe 'CSAT Survey Responses API', type: :request do
  let(:account) { create(:account) }
  let!(:csat_survey_response) { create(:csat_survey_response, account: account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/csat_survey_responses' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns all the csat survey responses for administrators' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.first['feedback_message']).to eq(csat_survey_response.feedback_message)
      end

      it 'filters csat responses based on a date range' do
        csat_10_days_ago = create(:csat_survey_response, account: account, created_at: 10.days.ago)
        csat_3_days_ago = create(:csat_survey_response, account: account, created_at: 3.days.ago)

        get "/api/v1/accounts/#{account.id}/csat_survey_responses",
            params: { since: 5.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s },
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data.pluck('id')).to include(csat_3_days_ago.id)
        expect(response_data.pluck('id')).not_to include(csat_10_days_ago.id)
      end

      it 'filters csat responses based on a date range and agent ids' do
        csat1_assigned_agent = create(:user, account: account, role: :agent)
        csat2_assigned_agent = create(:user, account: account, role: :agent)

        create(:csat_survey_response, account: account, created_at: 10.days.ago, assigned_agent: csat1_assigned_agent)
        create(:csat_survey_response, account: account, created_at: 3.days.ago, assigned_agent: csat2_assigned_agent)
        create(:csat_survey_response, account: account, created_at: 5.days.ago)

        get "/api/v1/accounts/#{account.id}/csat_survey_responses",
            params: { since: 11.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s,
                      user_ids: [csat1_assigned_agent.id, csat2_assigned_agent.id] },
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data.size).to eq 2
      end

      it 'returns csat responses even if the agent is deleted from account' do
        deleted_agent_csat = create(:csat_survey_response, account: account, assigned_agent: agent)
        deleted_agent_csat.assigned_agent.account_users.destroy_all

        get "/api/v1/accounts/#{account.id}/csat_survey_responses",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/csat_survey_responses/metrics' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns csat metrics for administrators' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data['total_count']).to eq 1
        expect(response_data['total_sent_messages_count']).to eq 0
        expect(response_data['ratings_count']).to eq({ '1' => 1 })
      end

      it 'filters csat metrics based on a date range' do
        # clearing any existing csat responses
        CsatSurveyResponse.destroy_all

        create(:csat_survey_response, account: account, created_at: 10.days.ago)
        create(:csat_survey_response, account: account, created_at: 3.days.ago)

        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
            params: { since: 5.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s },
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data['total_count']).to eq 1
        expect(response_data['total_sent_messages_count']).to eq 0
        expect(response_data['ratings_count']).to eq({ '1' => 1 })
      end

      it 'filters csat metrics based on a date range and agent ids' do
        csat1_assigned_agent = create(:user, account: account, role: :agent)
        csat2_assigned_agent = create(:user, account: account, role: :agent)

        create(:csat_survey_response, account: account, created_at: 10.days.ago, assigned_agent: csat1_assigned_agent)
        create(:csat_survey_response, account: account, created_at: 3.days.ago, assigned_agent: csat2_assigned_agent)
        create(:csat_survey_response, account: account, created_at: 5.days.ago)

        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
            params: { since: 11.days.ago.to_time.to_i.to_s, until: Time.zone.today.to_time.to_i.to_s,
                      user_ids: [csat1_assigned_agent.id, csat2_assigned_agent.id] },
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data['total_count']).to eq 2
        expect(response_data['total_sent_messages_count']).to eq 0
        expect(response_data['ratings_count']).to eq({ '1' => 2 })
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/csat_survey_responses/metrics with sent surveys' do
    let(:csat_survey_response) { nil }
    let(:inbox_a) { create(:inbox, account: account) }
    let(:inbox_b) { create(:inbox, account: account) }
    let(:since_time) { Time.utc(2026, 9, 17) }
    let(:until_time) { Time.utc(2026, 9, 18) }
    let(:date_params) { { since: since_time.to_i.to_s, until: until_time.to_i.to_s, timezone_offset: 0 } }

    before do
      [inbox_a, inbox_b].each do |inbox|
        conversation = create(:conversation, account: account, inbox: inbox)
        message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                   message_type: :template, content_type: :input_csat, created_at: since_time + 12.hours)
        create(:csat_survey_response, account: account, conversation: conversation, contact: conversation.contact,
                                      message: message, rating: 5, created_at: since_time + 13.hours)
      end
    end

    [:inbox_a, :inbox_b].each do |inbox_name|
      it "counts only sent surveys in #{inbox_name}" do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
            params: date_params.merge(inbox_id: public_send(inbox_name).id), headers: administrator.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include('total_count' => 1, 'total_sent_messages_count' => 1)
      end
    end

    it 'counts both inboxes when no inbox is selected' do
      get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
          params: date_params, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('total_count' => 2, 'total_sent_messages_count' => 2)
    end

    it 'counts both inboxes when the inbox is blank' do
      get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
          params: date_params.merge(inbox_id: ''), headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('total_count' => 2, 'total_sent_messages_count' => 2)
    end

    it 'filters by inbox without a date range' do
      get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
          params: { inbox_id: inbox_a.id }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('total_count' => 1, 'total_sent_messages_count' => 1)
    end

    it 'excludes surveys belonging to another account' do
      other_conversation = create(:conversation)
      message = create(:message, account: other_conversation.account, inbox: other_conversation.inbox, conversation: other_conversation,
                                 message_type: :template, content_type: :input_csat, created_at: since_time + 12.hours)
      create(:csat_survey_response, account: other_conversation.account, conversation: other_conversation,
                                    contact: other_conversation.contact, message: message, created_at: since_time + 13.hours)

      get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
          params: date_params, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('total_count' => 2, 'total_sent_messages_count' => 2)
    end

    it 'includes the start boundary but excludes the end boundary and earlier surveys' do
      [since_time - 1.second, since_time, until_time].each do |created_at|
        conversation = create(:conversation, account: account, inbox: inbox_a)
        message = create(:message, account: account, inbox: inbox_a, conversation: conversation,
                                   message_type: :template, content_type: :input_csat, created_at: created_at)
        create(:csat_survey_response, account: account, conversation: conversation, contact: conversation.contact,
                                      message: message, rating: 5, created_at: created_at)
      end

      get "/api/v1/accounts/#{account.id}/csat_survey_responses/metrics",
          params: date_params.merge(inbox_id: inbox_a.id), headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('total_count' => 2, 'total_sent_messages_count' => 2)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/csat_survey_responses/download' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/download"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:params) { { since: 5.days.ago.to_time.to_i.to_s, until: Time.zone.tomorrow.to_time.to_i.to_s } }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/download",
            params: params,
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns summary' do
        get "/api/v1/accounts/#{account.id}/csat_survey_responses/download",
            params: params,
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)

        content = CSV.parse(response.body)
        # Check rating from CSAT Row
        expect(content[1][1]).to eq '1'
        expect(content.length).to eq 3
      end

      it 'neutralises formula-leading characters in the feedback column' do
        create(:csat_survey_response, account: account, feedback_message: '=1+1', created_at: 1.day.ago)

        get "/api/v1/accounts/#{account.id}/csat_survey_responses/download",
            params: params,
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        injected = CSV.parse(response.body).map { |row| row[2] }.find { |value| value.to_s.include?('1+1') }
        expect(injected).to start_with("'")
      end
    end
  end
end
