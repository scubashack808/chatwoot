require 'rails_helper'

RSpec.describe Imap::ConversationMailboxState do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  it 'derives one role without writing a conversation projection' do
    message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
    )

    expect(described_class.new(conversation: conversation).to_h).to eq(
      state: 'inbox',
      roles: ['inbox'],
      tracked_count: 1,
      untracked_count: 0,
      missing_count: 0,
      conflict_count: 0
    )
    expect(conversation.reload.additional_attributes).not_to have_key('mail_folder')
  end

  it 'reports mixed locations, untracked mail, provider absence, and the latest operation conflicts' do
    inbox_message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    inbox_message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
    )
    archived_message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    archived_message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX.Archive', uidvalidity: 99, uid: 21, roles: ['archive'])
    )
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    missing_message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    missing_identity = Imap::MessageIdentity.build(mailbox: 'INBOX.Trash', uidvalidity: 100, uid: 31, roles: ['trash']).to_h
    missing_identity['sync_state'] = 'missing'
    missing_message.update!(
      external_source_ids: missing_message.external_source_ids.merge(Imap::MessageIdentity::NAMESPACE => missing_identity)
    )
    create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversation,
      action: :archive,
      status: :partially_succeeded,
      items: [{ 'message_id' => inbox_message.id }, { 'message_id' => archived_message.id }],
      results: [
        { 'message_id' => inbox_message.id, 'status' => 'succeeded' },
        { 'message_id' => archived_message.id, 'status' => 'conflict' }
      ]
    )

    expect(described_class.new(conversation: conversation).to_h).to eq(
      state: 'mixed',
      roles: %w[inbox archive],
      tracked_count: 2,
      untracked_count: 1,
      missing_count: 1,
      conflict_count: 1
    )
  end

  it 'never counts outgoing Sent copies in conversation mailbox state' do
    outgoing = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
    outgoing.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: 'INBOX.Sent', uidvalidity: 102, uid: 50, roles: ['sent'])
    )

    expect(described_class.new(conversation: conversation).to_h).to include(
      roles: [],
      tracked_count: 0,
      untracked_count: 0
    )
  end

  it 'uses Gmail system-role precedence while preserving unrelated multi-location labels' do
    message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    identity = Imap::MessageIdentity
               .build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001')
               .with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 99, uid: 31, roles: ['archive'])
    message.write_imap_identity!(identity)

    expect(described_class.new(conversation: conversation).to_h).to include(state: 'inbox', roles: ['inbox'])

    trashed = identity.with_location(mailbox: '[Gmail]/Trash', uidvalidity: 100, uid: 44, roles: ['trash'])
    message.write_imap_identity!(trashed)

    expect(described_class.new(conversation: conversation).to_h).to include(state: 'trash', roles: ['trash'])
  end
end
