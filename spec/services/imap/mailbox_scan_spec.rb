require 'rails_helper'

RSpec.describe Imap::MailboxScan do
  let(:imap) { instance_double(Net::IMAP, capabilities: []) }
  let(:session) { instance_double(Imap::Session) }
  let(:server) { { 'INBOX' => { uidvalidity: 777, uids: [11, 12] }, 'INBOX.Archive' => { uidvalidity: 778, uids: [5] } } }
  let(:dropped_fetch_responses) { Hash.new(0) }

  def scan(max_messages: nil)
    described_class.new(client: imap, session: session, mailboxes: [%w[INBOX inbox], %w[INBOX.Archive archive]],
                        max_messages: max_messages).perform
  end

  def location(mailbox, uidvalidity, uid)
    Imap::MessageIdentity.location_for(mailbox: mailbox, uidvalidity: uidvalidity, uid: uid)
  end

  before do
    allow(session).to receive(:command).and_yield(imap)

    current = 'INBOX'
    allow(imap).to receive(:examine) { |mailbox| current = mailbox }
    allow(imap).to receive(:responses).with('UIDVALIDITY') { [server.fetch(current)[:uidvalidity]] }
    allow(imap).to receive(:uid_search).with(['ALL']) { server.fetch(current)[:uids] }
    allow(imap).to receive(:uid_fetch) do |batch, _attributes|
      uids = server.fetch(current)[:uids] & Array(batch)
      uids.first(uids.length - dropped_fetch_responses[current]).map do |uid|
        Net::IMAP::FetchData.new(uid, 'UID' => uid, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "Message-ID: <#{uid}@example.com>\r\n\r\n")
      end
    end
  end

  it 'retains nothing from a complete scan' do
    result = scan

    expect(result).to be_conclusive
    expect(result.retained?(location('INBOX', 777, 11))).to be false
  end

  it 'retains the listed UIDs of a window whose fetch came back short' do
    dropped_fetch_responses['INBOX'] = 1

    result = scan

    expect(result).not_to be_conclusive
    expect(result.retained?(location('INBOX', 777, 12))).to be true
    expect(result.retained?(location('INBOX', 777, 99))).to be false
    expect(result.retained?(location('INBOX.Archive', 778, 5))).to be false
  end

  it 'retains the listed UIDs of a window larger than the bound' do
    result = scan(max_messages: 1)

    expect(result).not_to be_conclusive
    expect(result.retained?(location('INBOX', 777, 11))).to be true
    expect(result.retained?(location('INBOX.Archive', 778, 5))).to be false
  end

  it 'does not retain a UID from a different UIDVALIDITY generation' do
    dropped_fetch_responses['INBOX'] = 1

    expect(scan.retained?(location('INBOX', 776, 11))).to be false
  end
end
