require 'rails_helper'

RSpec.describe Imap::SentImportProgress do
  let(:channel) { create(:channel_email, :imap_email) }
  let(:sent_mailbox) { instance_double(Imap::SentMailbox, mailbox: 'INBOX.Sent', uidvalidity: 777) }
  let(:progress) { described_class.new(channel: channel, sent_mailbox: sent_mailbox, interval: 1) }

  before do
    allow(sent_mailbox).to receive(:search_since).and_return((1..201).to_a.reverse)
  end

  it 'persists a sorted unique snapshot before processing and resumes it with a fresh channel' do
    allow(sent_mailbox).to receive(:search_since).and_return(['3', 2, 1, 2])

    expect(progress.select(limit: 2)).to eq [1, 2]
    expect(channel.reload.sent_import_progress['pending_uids']).to eq [1, 2, 3]
    progress.acknowledge(uids: [1, 2], retry_uids: [])

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(resumed.select(limit: 2)).to eq [3]
    expect(sent_mailbox).to have_received(:search_since).once
  end

  it 'reserves half the batch for each queue and rotates failed retries behind untouched retries' do
    selected = progress.select(limit: 100)
    progress.acknowledge(uids: selected, retry_uids: selected)

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    selected = resumed.select(limit: 100)
    expect(selected).to eq((101..150).to_a + (1..50).to_a)
    resumed.acknowledge(uids: selected, retry_uids: selected)

    next_pass = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(next_pass.select(limit: 100)).to eq((151..200).to_a + (51..100).to_a)
  end

  it 'lends unused retry capacity to pending work' do
    progress.select(limit: 100)
    progress.acknowledge(uids: (1..100).to_a, retry_uids: [1])

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(resumed.select(limit: 100)).to eq((101..199).to_a + [1])
  end

  it 'lends unused pending capacity to retries' do
    allow(sent_mailbox).to receive(:search_since).and_return((1..101).to_a)
    selected = progress.select(limit: 100)
    progress.acknowledge(uids: selected, retry_uids: selected)

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(resumed.select(limit: 100)).to eq([101] + (1..99).to_a)
  end

  it 'keeps retried UIDs out of new snapshots and removes successful retries' do
    allow(sent_mailbox).to receive(:search_since).and_return([1, 2])
    selected = progress.select(limit: 100)
    progress.acknowledge(uids: selected, retry_uids: [1])

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(resumed.select(limit: 100)).to eq [2, 1]
    expect(channel.reload.sent_import_progress['pending_uids']).to eq [2]
    resumed.acknowledge(uids: [2, 1], retry_uids: [])

    expect(channel.reload.sent_import_progress).to include('retry_uids' => [], 'retry_since' => nil)
  end

  it 'rotates more than a batch of failures while completing a large pending snapshot' do
    allow(sent_mailbox).to receive(:search_since).and_return((1..10_001).to_a.reverse)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    selected = progress.select(limit: 100)
    snapshot_bytes = channel.reload.sent_import_progress.to_json.bytesize
    progress.acknowledge(uids: selected, retry_uids: selected)
    visited = selected.dup
    retry_visits = []

    200.times do
      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      selected = resumed.select(limit: 100)
      expect(selected.length).to be <= 100
      expect(selected.uniq).to eq selected
      visited.concat(selected)
      retry_visits.concat(selected & (1..150).to_a)
      resumed.acknowledge(uids: selected, retry_uids: selected & (1..150).to_a)
      break if channel.reload.sent_import_progress['pending_uids'].empty?
    end

    expect(visited.uniq.sort).to eq((1..10_001).to_a)
    expect(retry_visits.uniq.sort).to eq((1..150).to_a)
    expect(channel.reload.sent_import_progress).to include('retry_uids' => [], 'retry_attempts' => {})
    expect(sent_mailbox).to have_received(:search_since).once
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    RSpec.configuration.reporter.message("10,001 UID snapshot: #{snapshot_bytes} JSON bytes; traversal #{elapsed.round(3)}s")
  end

  it 'rejects stale acknowledgements without overwriting newer progress' do
    progress.select(limit: 100)
    stale = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    stale.select(limit: 100)
    progress.acknowledge(uids: (1..100).to_a, retry_uids: [])

    expect { stale.acknowledge(uids: (1..100).to_a, retry_uids: [1]) }.to raise_error(described_class::CheckpointConflict)
    expect(channel.reload.sent_import_progress).to include('pending_uids' => (101..201).to_a, 'retry_uids' => [])
  end

  it 'rejects a snapshot captured by a stale writer' do
    stale = described_class.new(channel: channel, sent_mailbox: sent_mailbox, interval: 1)
    progress.select(limit: 100)

    expect { stale.select(limit: 100) }.to raise_error(described_class::CheckpointConflict)
    expect(channel.reload.sent_import_progress['pending_uids']).to eq((1..201).to_a)
  end

  it 'does not store credentials or reset progress when credentials rotate' do
    channel.update!(imap_password: 'initial-secret', provider_config: { 'access_token' => 'initial-token' })
    progress.select(limit: 100)
    progress.acknowledge(uids: (1..100).to_a, retry_uids: [])
    channel.update!(imap_password: 'rotated-secret', provider_config: { 'access_token' => 'rotated-token' })

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    expect(resumed.select(limit: 100)).to eq((101..200).to_a)
    expect(channel.reload.sent_import_progress.to_json).not_to match(/secret|token|password/)
    expect(sent_mailbox).to have_received(:search_since).once
  end

  it 'drops a UID after the retry cap and forgets attempts for UIDs that complete' do
    allow(sent_mailbox).to receive(:search_since).and_return([1, 2], [])
    selected = progress.select(limit: 100)
    progress.acknowledge(uids: selected, retry_uids: selected)

    resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
    resumed.acknowledge(uids: resumed.select(limit: 100), retry_uids: [1])
    expect(channel.reload.sent_import_progress['retry_attempts']).to eq('1' => 2)

    (described_class::MAX_RETRY_ATTEMPTS - 2).times do
      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(resumed.select(limit: 100)).to eq [1]
      resumed.acknowledge(uids: [1], retry_uids: [1])
    end

    expect(channel.reload.sent_import_progress).to include('retry_uids' => [], 'retry_attempts' => {}, 'retry_since' => nil)
  end

  it 'does not checkpoint a failed search' do
    allow(sent_mailbox).to receive(:search_since).and_raise(IOError)

    expect { progress.select(limit: 100) }.to raise_error(IOError)
    expect(channel.reload.sent_import_progress).to eq({})
  end

  context 'with date-sensitive searches' do
    before { travel_to Time.zone.local(2026, 10, 2, 23, 59) }

    it 'keeps captured work after rollover and searches from the previous start rather than completion' do
      progress.select(limit: 100)
      progress.acknowledge(uids: (1..100).to_a, retry_uids: [])
      travel_to Time.zone.local(2026, 10, 8, 0, 1)
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return([202])
      allow(sent_mailbox).to receive(:search_since).with('07-Oct-2026').and_return([])

      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(resumed.select(limit: 100)).to eq((101..200).to_a)
      resumed.acknowledge(uids: (101..200).to_a, retry_uids: [])
      last_batch = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(last_batch.select(limit: 100)).to eq [201]
      last_batch.acknowledge(uids: [201], retry_uids: [])

      next_sweep = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(next_sweep.select(limit: 100)).to eq [202]
      expect(channel.reload.sent_import_progress['next_since']).to eq '2026-10-07'
      expect(sent_mailbox).to have_received(:search_since).with('01-Oct-2026').twice
      expect(sent_mailbox).not_to have_received(:search_since).with('07-Oct-2026')
    end

    it 'retains failed UIDs after they disappear from the rolling search' do
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return([1])
      progress.select(limit: 100)
      progress.acknowledge(uids: [1], retry_uids: [1])
      travel_to Time.zone.local(2026, 10, 8)
      allow(sent_mailbox).to receive(:search_since).with('07-Oct-2026').and_return([])
      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(resumed.select(limit: 100)).to eq [1]
      resumed.acknowledge(uids: [1], retry_uids: [1])

      later = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(later.select(limit: 100)).to eq [1]
      expect(channel.reload.sent_import_progress['retry_since']).to eq '2026-10-01'
      expect(sent_mailbox).to have_received(:search_since).with('07-Oct-2026').once
    end

    it 'advances an empty window only from search start and searches once per selection' do
      allow(sent_mailbox).to receive(:search_since).and_return([])
      expect(progress.select(limit: 100)).to eq []
      travel_to Time.zone.local(2026, 10, 5)
      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(resumed.select(limit: 100)).to eq []

      expect(channel.reload.sent_import_progress).to include('active_since' => '2026-10-01', 'next_since' => '2026-10-04')
      expect(sent_mailbox).to have_received(:search_since).with('01-Oct-2026').twice
    end

    it 'rediscovers from the oldest retry date after consecutive generation changes' do
      allow(sent_mailbox).to receive(:search_since).and_return([1])
      progress.select(limit: 100)
      progress.acknowledge(uids: [1], retry_uids: [1])
      travel_to Time.zone.local(2026, 10, 8)
      resumed = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      resumed.select(limit: 100)
      resumed.acknowledge(uids: [1], retry_uids: [1])

      allow(sent_mailbox).to receive(:uidvalidity).and_return(778)
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return([300, 301])
      reset = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(reset.select(limit: 1)).to eq [300]
      expect(channel.reload.sent_import_progress['retry_uids']).to eq []
      reset.acknowledge(uids: [300], retry_uids: [])

      allow(sent_mailbox).to receive(:uidvalidity).and_return(779)
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return([400])
      second_reset = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(second_reset.select(limit: 100)).to eq [400]
      expect(channel.reload.sent_import_progress['source']['uidvalidity']).to eq 779
      expect(sent_mailbox).to have_received(:search_since).with('01-Oct-2026').exactly(4).times
    end

    it 'discards old UID identities when the mailbox or connection changes' do
      progress.select(limit: 100)
      travel_to Time.zone.local(2026, 10, 8)
      allow(sent_mailbox).to receive(:mailbox).and_return('Sent Items')
      allow(sent_mailbox).to receive(:search_since).with('01-Oct-2026').and_return([900])
      channel.update!(imap_address: 'new.example.test', imap_login: 'other@example.test')

      reset = described_class.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
      expect(reset.select(limit: 100)).to eq [900]
      expect(channel.reload.sent_import_progress['source']).to include('mailbox' => 'Sent Items', 'address' => 'new.example.test')
    end
  end
end
