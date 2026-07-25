require 'rails_helper'

RSpec.describe 'Conversation mailbox operations API', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:idempotency_key) { SecureRandom.uuid }
  let!(:incoming_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, source_id: 'tracked@example.com')
  end
  let!(:outgoing_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, source_id: 'outgoing@example.com')
  end

  before do
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'active' })
    incoming_message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
    )
  end

  describe 'POST /api/v1/accounts/:account_id/conversations/:conversation_id/mailbox_operations' do
    it 'accepts an administrator request and freezes only eligible incoming message identities' do
      expect do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
             params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
             headers: administrator.create_new_auth_token,
             as: :json
      end.to change(EmailMailboxOperation, :count).by(1)

      expect(response).to have_http_status(:accepted)

      operation = EmailMailboxOperation.last
      expect(operation).to have_attributes(account: account, inbox: inbox, conversation: conversation,
                                           user: administrator, action: 'archive', status: 'pending')
      expect(operation.frozen_items).to contain_exactly(
        include(
          'message_id' => incoming_message.id,
          'identity_version' => 1,
          'source' => include('mailbox' => 'INBOX', 'uidvalidity' => 42, 'uid' => 7)
        )
      )
      expect(operation.frozen_items.pluck('message_id')).not_to include(outgoing_message.id)
      expect(response.parsed_body.dig('operation', 'id')).to eq(operation.id)
      expect(EmailMailboxOperationJob).to have_been_enqueued.with(operation.id)
    end

    it 'accepts an explicit inbox member who is not an administrator' do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(EmailMailboxOperation.last.user).to eq(agent)
    end

    it 'freezes an untracked incoming message as a visible conflict instead of counting it as success' do
      untracked_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        source_id: 'untracked@example.com'
      )

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(EmailMailboxOperation.last.frozen_items).to include(
        include('message_id' => untracked_message.id, 'preflight_error' => 'identity_missing')
      )
      expect(response.parsed_body.dig('operation', 'total')).to eq(2)
    end

    it 'freezes the actionable Inbox location when Gmail All Mail is the stored primary location' do
      identity = Imap::MessageIdentity
                 .build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001')
                 .with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 99, uid: 31, roles: ['archive'])
      incoming_message.write_imap_identity!(identity)

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(EmailMailboxOperation.last.frozen_items.first['source']).to include(
        'mailbox' => 'INBOX', 'uidvalidity' => 42, 'uid' => 7
      )
    end

    it 'refuses an agent who can access the account but is not an explicit inbox member' do
      agent = create(:user, account: account, role: :agent)

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(EmailMailboxOperation).not_to exist
    end

    it 'refuses observe mode without creating an operation' do
      channel.update!(mailbox_sync_config: { 'mode' => 'observe' })

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error_code']).to eq('mailbox_sync_not_active')
      expect(EmailMailboxOperation).not_to exist
    end

    it 'refuses off mode without creating an operation' do
      channel.update!(mailbox_sync_config: { 'mode' => 'off' })

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error_code']).to eq('mailbox_sync_not_active')
      expect(EmailMailboxOperation).not_to exist
    end

    it 'refuses while the account mutation kill switch is off' do
      account.disable_features!(:email_mailbox_actions)

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error_code']).to eq('mailbox_actions_disabled')
      expect(EmailMailboxOperation).not_to exist
    end

    it 'returns the original operation when the same request repeats with the same idempotency key' do
      2.times do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
             params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
             headers: administrator.create_new_auth_token,
             as: :json
      end

      expect(response).to have_http_status(:accepted)
      expect(EmailMailboxOperation.where(idempotency_key: idempotency_key).count).to eq(1)
    end

    it 'resumes only the unresolved items of a partial operation under the same idempotency key' do
      operation = create(
        :email_mailbox_operation,
        account: account,
        inbox: inbox,
        conversation: conversation,
        user: administrator,
        action: :archive,
        idempotency_key: idempotency_key,
        status: :partially_succeeded,
        items: [{ 'message_id' => incoming_message.id }, { 'message_id' => incoming_message.id + 1 }],
        results: [{ 'message_id' => incoming_message.id, 'status' => 'succeeded' }]
      )

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(operation.reload.status).to eq 'pending'
      expect(operation.unresolved_items.pluck('message_id')).to eq [incoming_message.id + 1]
      expect(EmailMailboxOperation.where(conversation_id: conversation.id).count).to eq(1)
    end

    it 'returns a visible conflict for a second nonterminal action on the conversation' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'archive', idempotency_key: idempotency_key } },
           headers: administrator.create_new_auth_token,
           as: :json

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations",
           params: { mailbox_operation: { action: 'trash', idempotency_key: SecureRandom.uuid } },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error_code']).to eq('operation_in_progress')
      expect(EmailMailboxOperation.count).to eq(1)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/:conversation_id/mailbox_operations/:id' do
    it 'returns the durable operation summary' do
      operation = create(
        :email_mailbox_operation,
        account: account,
        inbox: inbox,
        conversation: conversation,
        user: administrator,
        action: :archive,
        idempotency_key: idempotency_key,
        items: [{ 'message_id' => incoming_message.id }]
      )

      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mailbox_operations/#{operation.id}",
          headers: administrator.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['operation']).to include(
        'id' => operation.id,
        'action' => 'archive',
        'status' => 'pending',
        'total' => 1
      )
    end
  end
end
