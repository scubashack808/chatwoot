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

  it 'dispatches only the safe summary and derived state under the dedicated event' do
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
        mailbox_state: Imap::ConversationMailboxState.new(conversation: conversation).to_h
      }
    )
  end

  it 'swallows a dispatcher failure after durable operation state is written' do
    operation
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_raise(StandardError, 'broadcast unavailable')

    expect { described_class.call(operation) }.not_to raise_error
    expect(operation.reload.status).to eq 'succeeded'
  end
end
