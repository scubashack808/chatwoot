require 'rails_helper'

RSpec.describe Imap::SentInboundImport do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:sent_mailbox) { instance_double(Imap::SentMailbox, mailbox: 'INBOX.Sent', uidvalidity: 777) }
  let(:searched_uids) { (1..101).to_a.shuffle(random: Random.new(58)) }
  let(:reply_uids) { [1, searched_uids.max] }
  let(:requests) { [] }
  let(:raw_messages) do
    searched_uids.to_h do |uid|
      references = reply_uids.include?(uid) ? "In-Reply-To: <root@example.test>\r\n" : ''
      [uid, "From: agent@example.test\r\nTo: customer@example.test\r\nSubject: Re: booking\r\n" \
            "Message-ID: <sent-#{uid}@example.test>\r\n#{references}Content-Type: text/plain\r\n\r\nExternal reply #{uid}.\r\n"]
    end
  end

  before do
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'provider_managed' })
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, source_id: 'root@example.test')
    allow(sent_mailbox).to receive(:search_since).and_return(searched_uids)
    allow(sent_mailbox).to receive(:fetch_headers) do |uids|
      requests << uids.dup
      uids.reverse.map { |uid| Net::IMAP::FetchData.new(uid, 'UID' => uid, 'BODY[HEADER]' => raw_messages.fetch(uid)) }
    end
    allow(sent_mailbox).to receive(:fetch_body) { |uid| raw_messages.fetch(uid) }
  end

  it 'covers a shuffled stable 101-UID search across bounded passes and imports both ends exactly once' do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, source_id: 'sent-50@example.test')

    reports = Array.new(4) { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }

    expect(requests.first(2).flatten.sort).to eq((1..101).to_a)
    expect(requests.map(&:length)).to all(be <= 100)
    expect(reports.sum { |report| report[:imported] }).to eq 2
    expect(reports.sum { |report| report[:already_present] }).to be >= 3
    reply_uids.each do |uid|
      messages = conversation.messages.where(source_id: "sent-#{uid}@example.test")
      expect(messages.count).to eq 1
      expect(messages.first.message_type).to eq 'outgoing'
      expect(messages.first.imap_identity.uid).to eq uid
    end
  end

  context 'with 201 stable shuffled candidates' do
    let(:searched_uids) { (1..201).to_a.shuffle(random: Random.new(58)) }

    it 'eventually visits the whole snapshot, not only the oldest reply' do
      reports = Array.new(3) { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }

      expect(requests.flatten.sort).to eq((1..201).to_a)
      expect(reports.map { |report| report[:examined] }).to eq [100, 100, 1]
      expect(conversation.messages.where(source_id: ['sent-1@example.test', 'sent-201@example.test']).count).to eq 2
    end
  end

  context 'with exactly 100 candidates' do
    let(:searched_uids) { (1..100).to_a }

    it 'imports replies exactly once across fresh importer instances' do
      first = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform
      second = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

      expect(first[:imported]).to eq 2
      expect(second[:imported]).to eq 0
      expect(second[:already_present]).to eq 2
      expect(requests).to eq [searched_uids, searched_uids]
      expect(conversation.messages.where(source_id: ['sent-1@example.test', 'sent-100@example.test']).count).to eq 2
    end
  end

  it 'does not create conversations or contacts for unthreaded mail' do
    allow(sent_mailbox).to receive(:search_since).and_return([2])

    expect { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }
      .to not_change(Conversation, :count).and not_change(Contact, :count).and not_change(Message, :count)
    expect(channel.reload.sent_import_progress['retry_uids']).to eq []
  end

  it 'retains a blank body and imports it after recovery without blocking later candidates' do
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(nil)
    described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(channel.reload.sent_import_progress['retry_uids']).to eq [1]
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(raw_messages.fetch(1))
    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(requests.last).to eq [101, 1]
    expect(report[:imported]).to eq 2
    expect(channel.reload.sent_import_progress['retry_uids']).to eq []
  end

  it 'retries transient body failures without losing the snapshot' do
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_raise(IOError)
    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(report[:failed]).to eq 1
    expect(channel.reload.sent_import_progress['retry_uids']).to eq [1]
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(raw_messages.fetch(1))
    described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
    expect(channel.reload.sent_import_progress['retry_uids']).to eq []
  end

  it 'keeps a permanently failing reply without starving other replies or retrying it twice per pass' do
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_raise(IOError)
    reports = Array.new(4) { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }

    expect(requests.first(2).flatten.uniq.sort).to eq((1..101).to_a)
    expect(requests.map(&:length)).to all(be <= 100)
    expect(requests).to all(satisfy { |uids| uids.count(1) <= 1 })
    expect(reports.sum { |report| report[:imported] }).to eq 1
    expect(conversation.messages.where(source_id: 'sent-101@example.test').count).to eq 1
    expect(channel.reload.sent_import_progress['retry_uids']).to eq [1]
  end

  it 'treats a UID expunged between SEARCH and FETCH as finished instead of retrying it forever' do
    fetched = []
    allow(sent_mailbox).to receive(:search_since).and_return([1, 2], [1])
    allow(sent_mailbox).to receive(:fetch_headers) do |uids|
      fetched.concat(uids)
      (uids - [2]).map { |uid| Net::IMAP::FetchData.new(uid, 'UID' => uid, 'BODY[HEADER]' => raw_messages.fetch(uid)) }
    end
    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(report.values_at(:examined, :missing, :imported)).to eq [2, 1, 1]
    expect(channel.reload.sent_import_progress).to include('pending_uids' => [], 'retry_uids' => [], 'retry_since' => nil)
    30.times { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }

    expect(channel.reload.sent_import_progress).to include('retry_uids' => [], 'retry_since' => nil)
    expect(fetched.count(2)).to eq 1
    expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
  end

  [nil, IOError].each do |failure|
    it "recovers exactly once after six #{failure || 'blank body'} failures spanning search-window expiry" do
      travel_to Time.zone.local(2026, 10, 2)
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return(searched_uids)
      allow(sent_mailbox).to receive(:search_since).with('07-Oct-2026').and_return([])
      allow(sent_mailbox).to receive(:fetch_body).with(1) { raise failure if failure }
      described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1).perform

      travel_to Time.zone.local(2026, 10, 8)
      5.times { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1).perform }

      expect(sent_mailbox).to have_received(:fetch_body).with(1).exactly(6).times
      expect(sent_mailbox).to have_received(:search_since).with('07-Oct-2026').at_least(:once)
      expect(channel.reload.sent_import_progress).to include('retry_uids' => [1], 'retry_since' => '2026-10-01')
      expect(conversation.messages.where(source_id: 'sent-101@example.test').count).to eq 1
      allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(raw_messages.fetch(1))
      3.times { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1).perform }

      expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
      expect(channel.reload.sent_import_progress).to include('retry_uids' => [], 'retry_since' => nil)
      expect(requests).to all(satisfy { |uids| uids.length <= 100 && uids.uniq == uids })
    end
  end

  it 'processes only selected UIDs once despite duplicate and unsolicited header responses' do
    allow(sent_mailbox).to receive(:search_since).and_return([1])
    allow(sent_mailbox).to receive(:fetch_headers).with([1]).and_return(
      [1, 1, 101].map { |uid| Net::IMAP::FetchData.new(uid, 'UID' => uid, 'BODY[HEADER]' => raw_messages.fetch(uid)) }
    )

    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(report[:examined]).to eq 1
    expect(report[:imported]).to eq 1
    expect(sent_mailbox).to have_received(:fetch_body).with(1).once
    expect(sent_mailbox).not_to have_received(:fetch_body).with(101)
  end

  it 'propagates search errors without checkpointing work' do
    allow(sent_mailbox).to receive(:search_since).and_raise(IOError)

    expect { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }.to raise_error(IOError)
    expect(channel.reload.sent_import_progress).to eq({})
    expect(sent_mailbox).not_to have_received(:fetch_headers)
  end

  it 'persists the snapshot before a header-fetch failure and replays it on the next pass' do
    allow(sent_mailbox).to receive(:fetch_headers).and_raise(IOError)

    expect { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }.to raise_error(IOError)
    expect(channel.reload.sent_import_progress['pending_uids']).to eq((1..101).to_a)
    allow(sent_mailbox).to receive(:fetch_headers) do |uids|
      uids.map { |uid| Net::IMAP::FetchData.new(uid, 'UID' => uid, 'BODY[HEADER]' => raw_messages.fetch(uid)) }
    end
    described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(sent_mailbox).to have_received(:search_since).once
    expect(channel.reload.sent_import_progress['pending_uids']).to eq [101]
    expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
  end

  it 'propagates lease loss and leaves all selected work unacknowledged' do
    allow(sent_mailbox).to receive(:fetch_body).with(1).and_raise(Imap::Lease::LeaseLostError)

    expect { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }.to raise_error do |error|
      expect(error.class.name).to eq 'Imap::Lease::LeaseLostError'
    end
    expect(channel.reload.sent_import_progress['pending_uids']).to eq((1..101).to_a)
    expect(channel.sent_import_progress['retry_uids']).to eq []
    expect(conversation.messages.where(source_id: 'sent-1@example.test')).not_to exist
  end

  it 'replays an interrupted checkpoint without importing an already committed message again' do
    progress = Imap::SentImportProgress.new(channel: channel, sent_mailbox: sent_mailbox, interval: 1)
    allow(Imap::SentImportProgress).to receive(:new).and_return(progress)
    allow(progress).to receive(:acknowledge).and_raise(Imap::SentImportProgress::CheckpointConflict)

    expect { described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform }.to raise_error do |error|
      expect(error.class.name).to eq 'Imap::SentImportProgress::CheckpointConflict'
    end
    expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
    expect(channel.reload.sent_import_progress['pending_uids']).to eq((1..101).to_a)
    allow(Imap::SentImportProgress).to receive(:new).and_call_original
    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(report.values_at(:already_present, :imported)).to eq [1, 0]
    expect(conversation.messages.where(source_id: 'sent-1@example.test').count).to eq 1
    expect(channel.reload.sent_import_progress['pending_uids']).to eq [101]
  end

  it 'rolls back message creation when identity persistence fails and retries the complete import' do
    importer = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox)
    allow(importer).to receive(:create_message).and_wrap_original do |original, *args|
      original.call(*args).tap { |message| allow(message).to receive(:write_imap_sent_sync!).and_raise(IOError) }
    end
    report = importer.perform

    expect(report[:failed]).to eq 1
    expect(conversation.messages.where(source_id: 'sent-1@example.test')).not_to exist
    expect(channel.reload.sent_import_progress['retry_uids']).to eq [1]
    report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

    expect(report[:imported]).to eq 2
    message = conversation.messages.find_by!(source_id: 'sent-1@example.test')
    expect(message.imap_identity.uid).to eq 1
    expect(channel.reload.sent_import_progress['retry_uids']).to eq []
  end

  context 'when the original search window expires' do
    before { travel_to Time.zone.local(2026, 10, 2, 23, 59) }

    it 'imports captured pending work and failed replies even when a new rolling search would omit them' do
      allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(nil)
      described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform
      travel_to Time.zone.local(2026, 10, 8, 0, 1)
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return(searched_uids)
      allow(sent_mailbox).to receive(:search_since).with('07-Oct-2026').and_return([])
      allow(sent_mailbox).to receive(:fetch_body).with(1).and_return(raw_messages.fetch(1))

      report = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox).perform

      expect(report[:imported]).to eq 2
      expect(requests.last).to eq [101, 1]
      expect(sent_mailbox).to have_received(:search_since).once
      expect(channel.reload.sent_import_progress['retry_uids']).to eq []
      expect(conversation.messages.where(source_id: ['sent-1@example.test', 'sent-101@example.test']).count).to eq 2
    end
  end
end
