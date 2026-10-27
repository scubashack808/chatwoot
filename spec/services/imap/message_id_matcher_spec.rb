require 'rails_helper'

RSpec.describe Imap::MessageIdMatcher do
  let(:imap) { instance_double(Net::IMAP) }
  let(:session) { instance_double(Imap::Session) }

  before do
    allow(session).to receive(:command).and_yield(imap)
  end

  it 'does not fetch an empty candidate set' do
    expect(imap).not_to receive(:uid_fetch)
    expect(described_class.call(session: session, uids: [], message_id: 'abc@example.com')).to eq []
  end

  [
    [['xabc@example.com'], []],
    [['abc@example.com'], [31]],
    [['xabc@example.com', 'abc@example.com'], [32]],
    [['abc@example.com', 'abc@example.com'], [31, 32]],
    [['ABC@example.com'], []]
  ].each do |ids, expected|
    it "matches parsed identities exactly for #{ids.inspect}" do
      uids = (31...(31 + ids.size)).to_a
      rows = ids.each_with_index.map do |id, index|
        Net::IMAP::FetchData.new(index + 1, { 'UID' => index + 31, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "Message-ID: <#{id}>\r\n\r\n" })
      end
      expect(imap).to receive(:uid_fetch).with(uids, ['UID', 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]']).and_return(rows)

      expect(described_class.call(session: session, uids: uids, message_id: 'abc@example.com')).to eq expected
    end
  end

  it 'ignores vanished candidates and headers without a Message-ID' do
    rows = [Net::IMAP::FetchData.new(1, { 'UID' => 31, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "\r\n" })]
    allow(imap).to receive(:uid_fetch).and_return(rows, nil)

    expect(described_class.call(session: session, uids: [31, 32], message_id: 'abc@example.com')).to eq []
    expect(described_class.call(session: session, uids: [31, 32], message_id: 'abc@example.com')).to eq []
  end
end
