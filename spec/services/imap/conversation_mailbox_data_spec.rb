require 'rails_helper'

RSpec.describe Imap::ConversationMailboxData do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }

  it 'bulk derives state and the latest operation for each conversation' do
    conversations = create_list(:conversation, 2, account: account, inbox: inbox)
    messages = conversations.map do |conversation|
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    end
    messages.first.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'Archive', uidvalidity: 42, uid: 8, roles: ['archive'])
    )
    messages.second.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'Trash', uidvalidity: 42, uid: 9, roles: ['trash'])
    )
    older_operation = create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversations.first,
      action: :archive,
      status: :succeeded,
      created_at: 2.minutes.ago
    )
    latest_operation = create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversations.first,
      action: :trash,
      status: :failed,
      created_at: 1.minute.ago
    )

    data = described_class.new(conversations: conversations).to_h

    expect(data.dig(conversations.first.id, :mailbox_state, :state)).to eq('archive')
    expect(data.dig(conversations.first.id, :mailbox_operation, :id)).to eq(latest_operation.id)
    expect(data.dig(conversations.second.id, :mailbox_state, :state)).to eq('trash')
    expect(data.dig(conversations.second.id, :mailbox_operation)).to be_nil
    expect(data.dig(conversations.first.id, :mailbox_operation, :id)).not_to eq(older_operation.id)
  end

  it 'keeps mailbox read query count constant as the conversation list grows' do
    query_counts = [1, 5].map do |conversation_count|
      conversations = create_list(:conversation, conversation_count, account: account, inbox: inbox)
      conversations.each do |conversation|
        message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
        message.write_imap_identity!(
          Imap::MessageIdentity.build(mailbox: 'Archive', uidvalidity: 42, uid: message.id, roles: ['archive'])
        )
        create(:email_mailbox_operation, account: account, inbox: inbox, conversation: conversation)
      end

      queries = []
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached] || payload[:name] == 'SCHEMA'
        next unless payload[:sql].start_with?('SELECT')

        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        described_class.new(conversations: conversations).to_h
      end
      queries.length
    end

    expect(query_counts).to eq([2, 2])
  end
end
