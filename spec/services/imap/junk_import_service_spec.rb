require 'rails_helper'

RSpec.describe Imap::JunkImportService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account, mailbox_sync_config: { 'mode' => 'observe' }) }
  let(:inbox) { channel.inbox }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox.id) }
  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Junk, :Hasnochildren], '.', 'INBOX.spam'),
      Net::IMAP::MailboxList.new([:Hasnochildren], '.', 'INBOX.Junk')
    ]
  end
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }
  # uid => raw message, standing in for the server's Junk folder.
  let(:junk_folder) { { 11 => raw_mail('spam-1@example.test'), 12 => raw_mail('spam-2@example.test') } }

  def raw_mail(message_id, from: 'spammer@example.test')
    Mail.new(from: from, to: channel.email, subject: 'Cheap watches', body: 'buy now', message_id: "<#{message_id}>").to_s
  end

  def header_data(uid)
    instance_double(Net::IMAP::FetchData, attr: { 'UID' => uid, 'BODY[HEADER]' => junk_folder[uid] })
  end

  def body_data(uid)
    instance_double(Net::IMAP::FetchData, attr: { 'BODY[]' => junk_folder[uid] })
  end

  before do
    account.enable_features!(:email_mailbox_actions)
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:capabilities).and_return(%w[IMAP4REV1 SPECIAL-USE])
    allow(imap).to receive(:list).with('', '*').and_return(folders)
    allow(imap).to receive(:examine)
    allow(imap).to receive(:responses).with('UIDVALIDITY').and_return([4242])
    allow(imap).to receive(:uid_search) { junk_folder.keys }
    allow(imap).to receive(:uid_fetch) do |uids, attributes|
      attributes.include?('BODY.PEEK[]') ? [body_data(uids)] : Array(uids).map { |uid| header_data(uid) }
    end
  end

  after { Redis::Alfred.delete(lease_key) }

  it 'reads the folder the server marks \\Junk, never by name, and only with EXAMINE' do
    report = described_class.new(channel: channel).perform

    expect(report).to include(status: 'completed', mailbox: 'INBOX.spam', examined: 2, imported: 2)
    expect(imap).to have_received(:examine).with('INBOX.spam')
    expect(imap).not_to have_received(:select).with('INBOX.spam')
  end

  it 'creates quiet, resolved conversations whose messages carry the spam role' do
    expect { described_class.new(channel: channel).perform }.to change(inbox.conversations, :count).by(2)

    conversation = inbox.conversations.last
    expect(conversation.reload).to be_resolved
    expect(conversation).to be_junk_import
    expect(conversation.messages.last.imap_identity).to have_attributes(mailbox: 'INBOX.spam', uidvalidity: 4242, roles: ['spam'])
  end

  it 'puts imported junk on the Spam tab and keeps it off the Inbox tab' do
    described_class.new(channel: channel).perform

    spam = Imap::MailboxRoleFilter.new(conversations: inbox.conversations, role: 'spam', account: account).perform
    inbox_view = Imap::MailboxRoleFilter.new(conversations: inbox.conversations, role: 'inbox', account: account).perform
    expect(spam.count).to eq 2
    expect(inbox_view.count).to eq 0
  end

  it 'imports nothing twice, and fetches no body for mail it already holds' do
    described_class.new(channel: channel).perform

    report = nil
    expect { report = described_class.new(channel: channel).perform }.not_to change(Message, :count)
    expect(report).to include(already_present: 2)
    expect(report[:imported].to_i).to eq 0
    expect(imap).to have_received(:uid_fetch).with(anything, ['BODY.PEEK[]']).twice
  end

  it 'skips what Chatwoot already holds before applying the per-cycle cap, so a busy day still drains' do
    stub_const("#{described_class}::MAX_PER_CYCLE", 1)
    create(:message, account: account, inbox: inbox, conversation: create(:conversation, account: account, inbox: inbox),
                     source_id: 'spam-2@example.test')

    report = described_class.new(channel: channel).perform

    expect(report).to include(already_present: 1, imported: 1)
    expect(inbox.messages.where(source_id: 'spam-1@example.test')).to exist
  end

  it 'skips when no folder claims \\Junk rather than guessing one' do
    allow(imap).to receive(:list).with('', '*').and_return([Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX')])

    report = described_class.new(channel: channel).perform

    expect(report).to include(status: 'skipped', reason: 'junk_folder_unavailable', detail: 'unavailable')
    expect(imap).not_to have_received(:examine)
  end

  it 'stays dark when the account feature flag is off' do
    account.disable_features!(:email_mailbox_actions)

    expect(described_class.new(channel: channel).perform).to include(status: 'skipped', reason: 'feature_disabled')
    expect(Net::IMAP).not_to have_received(:new)
  end

  it 'stays dark when the inbox mailbox sync mode is off' do
    channel.update!(mailbox_sync_config: { 'mode' => 'off' })

    expect(described_class.new(channel: channel).perform).to include(status: 'skipped', reason: 'mailbox_sync_off')
  end
end
