require 'rails_helper'

RSpec.describe Imap::ConversationMailboxData do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }

  # Publication now requires the inbox to be at mode active. Written past validation on purpose:
  # entering active legitimately contacts the mail server, and these examples are about what is
  # published, not about how an inbox gets activated. Channel::Email's own spec covers that.
  def activate!(target = channel)
    target.update_column(:mailbox_sync_config,
                         { 'mode' => 'active', 'sent_mode' => 'provider_managed', 'folder_overrides' => {} })
    target.reload
  end

  def tracked_message(conversation, mailbox: 'Archive', roles: ['archive'])
    message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                               message_type: :incoming)
    message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: mailbox, uidvalidity: 42, uid: message.id, roles: roles)
    )
    message
  end

  before { activate! }

  it 'bulk derives state and the latest operation for each conversation' do
    conversations = create_list(:conversation, 2, account: account, inbox: inbox)
    tracked_message(conversations.first, mailbox: 'Archive', roles: ['archive'])
    tracked_message(conversations.second, mailbox: 'Trash', roles: ['trash'])
    older_operation = create(
      :email_mailbox_operation,
      account: account, inbox: inbox, conversation: conversations.first,
      action: :archive, status: :succeeded, created_at: 2.minutes.ago
    )
    latest_operation = create(
      :email_mailbox_operation,
      account: account, inbox: inbox, conversation: conversations.first,
      action: :trash, status: :failed, created_at: 1.minute.ago
    )

    data = described_class.new(conversations: conversations).to_h

    expect(data.dig(conversations.first.id, :mailbox_state, :state)).to eq('archive')
    expect(data.dig(conversations.first.id, :mailbox_operation, :id)).to eq(latest_operation.id)
    expect(data.dig(conversations.second.id, :mailbox_state, :state)).to eq('trash')
    expect(data.dig(conversations.second.id, :mailbox_operation)).to be_nil
    expect(data.dig(conversations.first.id, :mailbox_operation, :id)).not_to eq(older_operation.id)
  end

  # Each of these is one of the ways the dashboard used to be handed a button that could only fail.
  # Absence of the key is the contract: the frontend tests for the property with hasOwnProperty, so
  # a nil value would still count as data and still draw the menu.
  describe 'the gate' do
    it 'publishes nothing while the inbox is below mode active' do
      channel.update_column(:mailbox_sync_config,
                            { 'mode' => 'observe', 'sent_mode' => 'provider_managed', 'folder_overrides' => {} })
      conversation = create(:conversation, account: account, inbox: channel.reload.inbox)
      tracked_message(conversation)

      expect(described_class.new(conversations: [conversation]).to_h).to eq({})
    end

    it 'publishes nothing for an inbox that is off' do
      channel.update_column(:mailbox_sync_config,
                            { 'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => {} })
      conversation = create(:conversation, account: account, inbox: channel.reload.inbox)
      tracked_message(conversation)

      expect(described_class.new(conversations: [conversation]).to_h).to eq({})
    end

    it 'omits a conversation whose incoming mail has no tracked identity' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

      expect(described_class.new(conversations: [conversation]).to_h).not_to have_key(conversation.id)
    end

    it 'omits a conversation with no incoming messages at all' do
      conversation = create(:conversation, account: account, inbox: inbox)

      expect(described_class.new(conversations: [conversation]).to_h).not_to have_key(conversation.id)
    end

    it 'publishes the tracked conversation and omits the untracked one on the same page' do
      tracked = create(:conversation, account: account, inbox: inbox)
      untracked = create(:conversation, account: account, inbox: inbox)
      tracked_message(tracked)
      create(:message, account: account, inbox: inbox, conversation: untracked, message_type: :incoming)

      data = described_class.new(conversations: [tracked, untracked]).to_h

      expect(data.keys).to eq([tracked.id])
    end

    it 'publishes only the active inbox when the page mixes inboxes' do
      other_channel = create(:channel_email, :imap_email, account: account)
      active_conversation = create(:conversation, account: account, inbox: inbox)
      inactive_conversation = create(:conversation, account: account, inbox: other_channel.inbox)
      tracked_message(active_conversation)
      tracked_message(inactive_conversation)

      data = described_class.new(conversations: [active_conversation, inactive_conversation]).to_h

      expect(data.keys).to eq([active_conversation.id])
    end
  end

  it 'keeps mailbox read query count constant as the conversation list grows' do
    query_counts = [1, 5].map do |conversation_count|
      conversations = create_list(:conversation, conversation_count, account: account, inbox: inbox)
      conversations.each do |conversation|
        tracked_message(conversation)
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

    # Four rather than the previous two: resolving which inboxes may mutate the provider costs one
    # query for the inboxes and one for their channels. What matters is that it does not grow with
    # the size of the page, and it does not.
    expect(query_counts).to eq([4, 4])
  end
end
