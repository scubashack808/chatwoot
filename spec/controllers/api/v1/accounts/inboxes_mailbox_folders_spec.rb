require 'rails_helper'

RSpec.describe 'Inbox mailbox folder discovery API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox.id) }

  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archive'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash')
    ]
  end

  before do
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:list).with('', '*').and_return(folders)
  end

  after { Redis::Alfred.delete(lease_key) }

  describe 'GET /api/v1/accounts/{account.id}/inboxes/:id/mailbox_folders' do
    context 'when the user is an administrator' do
      it 'returns the discovered folders and per role results' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['folders'].pluck('name')).to include('INBOX.Archive')
        expect(response.parsed_body['roles']['archive']['status']).to eq 'discovered'
        expect(response.parsed_body['roles']['archive']['selected']).to eq 'INBOX.Archive'
      end

      it 'reports a role with no usable folder as unavailable rather than guessing' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response.parsed_body['roles']['spam']['status']).to eq 'unavailable'
        expect(response.parsed_body['roles']['spam']['selected']).to be_nil
      end

      it 'never returns a credential in the payload' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response.body).not_to include(channel.imap_password)
        expect(response.body).not_to match(/password|token|secret/i)
      end

      it 'returns a conflict rather than a second connection when the mailbox is busy' do
        Imap::Lease.new(inbox_id: inbox.id, ttl: 30).acquire

        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:conflict)
      end

      it 'reports a server failure without leaking the raw exception' do
        allow(imap).to receive(:list).and_raise(Net::IMAP::Error, 'LIST failed: secret-server-detail')

        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include('secret-server-detail')
      end
    end

    context 'when the user is an agent' do
      before { create(:inbox_member, user: agent, inbox: inbox) }

      it 'refuses the request' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the user is unauthenticated' do
      it 'refuses the request' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/mailbox_folders"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the inbox is not an IMAP email inbox' do
      let(:web_inbox) { create(:inbox, account: account) }

      it 'refuses discovery' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{web_inbox.id}/mailbox_folders",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end
end
