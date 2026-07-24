require 'rails_helper'

RSpec.describe Imap::IdentityBackfillService do
  let(:account) { create(:account) }
  # Per-mailbox server contents, so a message in INBOX is not also seen in INBOX.Archive.
  let(:server) { { 'INBOX' => [], 'INBOX.Archive' => [] } }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true, capabilities: []) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox.id) }

  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archive')
    ]
  end

  def header_data(uid, message_id)
    Net::IMAP::FetchData.new(uid, 'UID' => uid,
                                  'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "Message-ID: <#{message_id}>\r\n\r\n")
  end

  def create_message(source_id)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, source_id: source_id)
  end

  before do
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:list).with('', '*').and_return(folders)
    allow(imap).to receive(:responses).with('UIDVALIDITY').and_return([777])

    current = nil
    allow(imap).to receive(:examine) { |mailbox| current = mailbox }
    allow(imap).to receive(:uid_search).with(['ALL']) { server.fetch(current, []).map { |d| d.attr['UID'] } }
    allow(imap).to receive(:uid_fetch) do |batch, _attributes|
      server.fetch(current, []).select { |d| Array(batch).include?(d.attr['UID']) }
    end
  end

  after { Redis::Alfred.delete(lease_key) }

  describe '#dry_run' do
    it 'never fetches a message body' do
      create_message('a@example.com')
      server['INBOX'] = [header_data(11, 'a@example.com')]

      described_class.new(channel: channel).dry_run

      expect(imap).to have_received(:uid_fetch).with(anything, array_including('BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]'))
      expect(imap).not_to have_received(:uid_fetch).with(anything, array_including('BODY.PEEK[]'))
    end

    it 'opens mailboxes read only so a dry run cannot mutate the server' do
      described_class.new(channel: channel).dry_run

      expect(imap).to have_received(:examine).with('INBOX')
      expect(imap).not_to have_received(:select).with('INBOX.Archive')
    end

    it 'reports an exact match when exactly one server message carries the message id' do
      message = create_message('a@example.com')
      server['INBOX'] = [header_data(11, 'a@example.com')]

      report = described_class.new(channel: channel).dry_run

      expect(report[:exact].length).to eq 1
      expect(report[:exact].first).to include(chatwoot_message_id: message.id, uid: 11, uidvalidity: 777, mailbox: 'INBOX')
      expect(report[:missing]).to be_empty
      expect(report[:ambiguous]).to be_empty
    end

    it 'reports missing when the server has no message with that message id' do
      create_message('gone@example.com')

      report = described_class.new(channel: channel).dry_run

      expect(report[:missing].length).to eq 1
      expect(report[:exact]).to be_empty
    end

    it 'reports ambiguous when the same message id appears in more than one place' do
      create_message('dupe@example.com')
      server['INBOX'] = [header_data(11, 'dupe@example.com'), header_data(12, 'dupe@example.com')]

      report = described_class.new(channel: channel).dry_run

      expect(report[:ambiguous].length).to eq 1
      expect(report[:exact]).to be_empty
    end

    it 'writes nothing at all' do
      message = create_message('a@example.com')
      server['INBOX'] = [header_data(11, 'a@example.com')]

      described_class.new(channel: channel).dry_run

      expect(message.reload.imap_identity).to be_nil
    end

    it 'reports which mailboxes it scanned with their uidvalidity' do
      report = described_class.new(channel: channel).dry_run

      expect(report[:mailboxes_scanned].map { |m| m[:mailbox] }).to include('INBOX')
      expect(report[:mailboxes_scanned].first[:uidvalidity]).to eq 777
    end

    it 'only considers incoming messages that carry a source id' do
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, source_id: nil)

      report = described_class.new(channel: channel).dry_run

      expect(report[:missing]).to be_empty
      expect(report[:candidates]).to eq 0
    end
  end

  describe '#apply' do
    let!(:message) { create_message('a@example.com') }

    before do
      server['INBOX'] = [header_data(11, 'a@example.com')]
    end

    it 'records the identity for an exact match' do
      described_class.new(channel: channel).apply

      identity = message.reload.imap_identity

      expect(identity.uid).to eq 11
      expect(identity.uidvalidity).to eq 777
      expect(identity.mailbox).to eq 'INBOX'
    end

    it 'reports how many identities it recorded' do
      expect(described_class.new(channel: channel).apply[:applied]).to eq 1
    end

    it 'is idempotent: a second apply changes nothing' do
      described_class.new(channel: channel).apply
      before_state = message.reload.external_source_ids

      second = described_class.new(channel: channel).apply

      expect(second[:applied]).to eq 0
      expect(message.reload.external_source_ids).to eq before_state
    end

    it 'never records an ambiguous match' do
      create_message('dupe@example.com')
      server['INBOX'] = [header_data(11, 'a@example.com'), header_data(12, 'dupe@example.com'), header_data(13, 'dupe@example.com')]

      described_class.new(channel: channel).apply

      expect(inbox.messages.find_by(source_id: 'dupe@example.com').imap_identity).to be_nil
    end

    it 'never records a missing match' do
      missing = create_message('gone@example.com')

      described_class.new(channel: channel).apply

      expect(missing.reload.imap_identity).to be_nil
    end

    it 'does not broadcast the identity it recorded' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      described_class.new(channel: channel).apply

      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
        .with(Message::MESSAGE_UPDATED, anything, hash_including(:message))
    end
  end

  describe 'a UIDVALIDITY change' do
    let!(:message) { create_message('a@example.com') }

    before do
      server['INBOX'] = [header_data(11, 'a@example.com')]
    end

    it 'reports a stored identity from a previous generation as stale' do
      message.write_imap_identity!(Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 1, uid: 99))

      report = described_class.new(channel: channel).dry_run

      expect(report[:stale].length).to eq 1
      expect(report[:stale].first).to include(chatwoot_message_id: message.id, stored_uidvalidity: 1, server_uidvalidity: 777)
    end

    it 're-anchors a stale identity onto the current generation on apply' do
      message.write_imap_identity!(Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 1, uid: 99))

      described_class.new(channel: channel).apply

      identity = message.reload.imap_identity

      expect(identity.uidvalidity).to eq 777
      expect(identity.uid).to eq 11
    end

    it 'never reuses the stale uid against the new generation' do
      message.write_imap_identity!(Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 1, uid: 99))

      described_class.new(channel: channel).apply

      expect(message.reload.imap_identity.uid).not_to eq 99
    end

    it 'treats an identity already on the current generation as already recorded' do
      message.write_imap_identity!(Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 777, uid: 11))

      report = described_class.new(channel: channel).dry_run

      expect(report[:already_recorded].length).to eq 1
      expect(report[:stale]).to be_empty
    end
  end

  describe 'lease behaviour' do
    it 'defers instead of opening a second connection when the mailbox is busy' do
      Imap::Lease.new(inbox_id: inbox.id, ttl: 30).acquire

      expect { described_class.new(channel: channel).dry_run }
        .to raise_error(Imap::Lease::LeaseNotAcquiredError)
    end

    it 'releases the lease afterwards' do
      described_class.new(channel: channel).dry_run

      expect(Redis::Alfred.exists?(lease_key)).to be false
    end
  end
end
