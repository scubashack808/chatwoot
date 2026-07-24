require 'rails_helper'

RSpec.describe 'Inbox mailbox sync configuration API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/:id' do
    let(:valid_config) do
      { mode: 'observe', sent_mode: 'append', folder_overrides: { archive: 'INBOX.Archives' } }
    end

    context 'when the user is an administrator' do
      it 'updates the mailbox sync configuration' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: valid_config } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(channel.reload.mailbox_sync.mode).to eq 'observe'
        expect(channel.reload.mailbox_sync.override_for(:archive)).to eq 'INBOX.Archives'
        expect(channel.reload.mailbox_sync.sent_mode).to eq 'append'
      end

      it 'returns the stored configuration in the inbox payload' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: valid_config } },
              headers: administrator.create_new_auth_token

        expect(response.parsed_body['mailbox_sync_config']['mode']).to eq 'observe'
      end

      it 'refuses an unknown key instead of storing it' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: { mode: 'off', imap_password: 'sneaky' } } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.mailbox_sync).to be_off
      end

      it 'refuses an unknown mode instead of storing it' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: { mode: 'delete_everything' } } },
              headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(channel.reload.mailbox_sync).to be_off
      end

      it 'leaves the inbox off until an administrator changes it' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: administrator.create_new_auth_token

        expect(response.parsed_body['mailbox_sync_config']['mode']).to eq 'off'
      end
    end

    context 'when the user is an agent' do
      before { create(:inbox_member, user: agent, inbox: inbox) }

      it 'refuses to update the mailbox sync configuration' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: valid_config } },
              headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
        expect(channel.reload.mailbox_sync).to be_off
      end

      it 'does not expose the mailbox sync configuration in the inbox payload' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: agent.create_new_auth_token

        expect(response.parsed_body).not_to have_key('mailbox_sync_config')
      end
    end

    context 'when the user is unauthenticated' do
      it 'refuses the update' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: { channel: { mailbox_sync_config: valid_config } }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
