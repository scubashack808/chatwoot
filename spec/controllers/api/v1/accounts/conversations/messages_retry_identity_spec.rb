require 'rails_helper'

# Review finding P3-4. The retry endpoint wipes content_attributes wholesale to clear the failure
# state. That wipe now also discards the agent's chosen From address, so a retried reply leaves
# from a different address than the first attempt. The agent sees one thread; the customer sees two
# senders, which is exactly the identity this row exists to preserve.
RSpec.describe 'Conversation message retry identity', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com']) }
  let(:inbox) { channel.inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, status: :failed,
                     content_attributes: { from_email: 'nonprofit@example.com', external_error: '502 5.5.1 Command not implemented' })
  end

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  def retry_message
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/retry",
         headers: agent.create_new_auth_token,
         as: :json
  end

  it 'keeps the agent chosen From address' do
    retry_message

    expect(response).to have_http_status(:success)
    expect(message.reload.content_attributes['from_email']).to eq('nonprofit@example.com')
  end

  it 'still resolves that address as the outbound identity' do
    retry_message

    expect(channel.outbound_address_for(conversation, message: message.reload)).to eq('nonprofit@example.com')
  end

  it 'still clears the failure state the wipe exists to clear' do
    retry_message

    expect(message.reload.status).to eq('sent')
    expect(message.reload.content_attributes['external_error']).to be_nil
  end

  it 'keeps nothing else the wipe was clearing' do
    message.update!(content_attributes: { from_email: 'nonprofit@example.com', external_error: 'boom', cc_emails: ['someone@example.com'] })

    retry_message

    expect(message.reload.content_attributes.keys).to contain_exactly('from_email')
  end
end
