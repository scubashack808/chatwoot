require 'rails_helper'

# Plan section 4: "Lease contention is not an action failure ... scheduled ingestion/reconciliation/
# Sent work defers to the next cycle. No consumer opens a second connection as a fallback."
RSpec.describe Inboxes::SyncImapSentJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account, mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'append' }) }
  let(:service) { instance_double(Imap::SentSyncService) }

  it 'runs the Sent sync for the channel' do
    allow(Imap::SentSyncService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_return({ status: 'completed' })

    described_class.perform_now(channel)

    expect(service).to have_received(:perform)
  end

  it 'retries with bounded jitter when another worker holds the per-inbox lease' do
    allow(Imap::SentSyncService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)
    allow(Imap::Lease).to receive(:retry_delay).with(0).and_return(7.0)

    expect { described_class.perform_now(channel) }
      .to have_enqueued_job(described_class).with(channel, 1, 1)
  end

  it 'stops retrying after the bounded lease retry limit' do
    allow(Imap::SentSyncService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.perform_now(channel, 1, described_class::LEASE_RETRY_LIMIT) }
      .not_to have_enqueued_job(described_class)
  end

  it 'does not run for a channel with IMAP disabled' do
    allow(Imap::SentSyncService).to receive(:new)
    channel.update!(imap_enabled: false)

    described_class.perform_now(channel)

    expect(Imap::SentSyncService).not_to have_received(:new)
  end

  it 'survives an IMAP transport failure without raising into the scheduler' do
    allow(Imap::SentSyncService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_raise(Net::IMAP::BadResponseError.new(
                                                    instance_double(Net::IMAP::TaggedResponse,
                                                                    data: instance_double(Net::IMAP::ResponseText, text: 'bad'))
                                                  ))

    expect { described_class.perform_now(channel) }.not_to raise_error
  end
end
