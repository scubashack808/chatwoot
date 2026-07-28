require 'rails_helper'

# Row 09 behaviour A01, API half: an administrator can manage the addresses that route into an
# email inbox, and the server refuses a collision rather than accepting two owners for one
# address.
RSpec.describe 'Inbox email aliases API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_email, account: account, email: 'care@example.com') }
  let(:inbox) { channel.inbox }

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/:id' do
    context 'when the user is an administrator' do
      it 'stores the aliases and returns them in the inbox payload' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['NonProfit@example.com', ' info@example.com '] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(channel.reload.aliases).to eq(['nonprofit@example.com', 'info@example.com'])
        expect(response.parsed_body['aliases']).to eq(['nonprofit@example.com', 'info@example.com'])
      end

      it 'reports an empty list for an inbox with no aliases' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: administrator.create_new_auth_token

        expect(response.parsed_body['aliases']).to eq([])
      end

      it 'refuses an alias already owned by another inbox' do
        create(:channel_email, account: account, email: 'sales@example.com', aliases: ['nonprofit@example.com'])

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['nonprofit@example.com'] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.aliases).to eq([])
      end

      it 'refuses an alias that is another inbox primary address' do
        create(:channel_email, account: account, email: 'sales@example.com')

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['sales@example.com'] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
      end

      # Review finding P2-1. The UI's vuelidate rule is not a server-side guard, so this is the
      # path a malformed alias actually arrives on.
      it 'refuses a malformed alias' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['not-an-address'] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.aliases).to eq([])
      end

      it 'refuses a display-name alias' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['"Info" <info@example.com>'] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.aliases).to eq([])
      end

      it 'stores a plus-addressed alias in the form the inbound finder looks up' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['Donations+2026@example.com'] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(channel.reload.aliases).to eq(['donations@example.com'])
        expect(response.parsed_body['aliases']).to eq(['donations@example.com'])
      end

      # Review finding P3-1.
      it 'refuses an alias that is another inbox forwarding address' do
        other = create(:channel_email, account: account, email: 'sales@example.com')

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: [other.forward_to_email] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.aliases).to eq([])
      end

      it 'clears the aliases when an empty list is sent' do
        channel.update!(aliases: ['nonprofit@example.com'])

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: [] } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(channel.reload.aliases).to eq([])
      end
    end

    context 'when the user is an agent' do
      it 'refuses the update' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['nonprofit@example.com'] } },
              headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
        expect(channel.reload.aliases).to eq([])
      end
    end

    context 'when the user is unauthenticated' do
      it 'refuses the update' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { aliases: ['nonprofit@example.com'] } }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
