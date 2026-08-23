require 'rails_helper'

RSpec.describe Imap::MailboxOperationNotifier do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_email, :imap_email, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:operation) do
    create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversation,
      action: :archive,
      status: :succeeded,
      items: [{ 'message_id' => 1 }],
      results: [{ 'message_id' => 1, 'status' => 'succeeded' }]
    )
  end

  # Publishable requires the inbox to be able to mutate the provider and the conversation to have a
  # tracked identity to address.
  def make_publishable
    inbox.channel.update!(mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'provider_managed',
                                                 'folder_overrides' => {} })
    message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
    )
    message
  end

  it 'dispatches only the safe summary and derived state under the dedicated event' do
    make_publishable
    allow(Rails.configuration.dispatcher).to receive(:dispatch)

    described_class.call(operation)

    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      kind_of(Time),
      {
        account_id: account.id,
        inbox_id: inbox.id,
        conversation_id: conversation.display_id,
        operation: operation.summary,
        mailbox_state: Imap::ConversationMailboxState.new(conversation: conversation.reload).to_h
      }
    )
  end

  # This is the third publication path and the easiest to forget. It reaches every inbox member
  # directly over the socket, so an ungated push here would put back exactly the buttons the payload
  # gate removes. The key must be absent rather than null, because the dashboard writes whatever
  # arrives onto its conversation object and then decides with hasOwnProperty.
  it 'omits mailbox state entirely when the inbox cannot mutate the provider' do
    allow(Rails.configuration.dispatcher).to receive(:dispatch)

    described_class.call(operation)

    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      kind_of(Time),
      hash_excluding(:mailbox_state)
    )
  end

  it 'omits mailbox state when the conversation has no tracked identity' do
    inbox.channel.update!(mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'provider_managed',
                                                 'folder_overrides' => {} })
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    allow(Rails.configuration.dispatcher).to receive(:dispatch)

    described_class.call(operation)

    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      kind_of(Time),
      hash_excluding(:mailbox_state)
    )
  end

  it 'swallows a dispatcher failure after durable operation state is written' do
    operation
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_raise(StandardError, 'broadcast unavailable')

    expect { described_class.call(operation) }.not_to raise_error
    expect(operation.reload.status).to eq 'succeeded'
  end
end
