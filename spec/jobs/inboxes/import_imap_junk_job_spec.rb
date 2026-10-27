require 'rails_helper'

RSpec.describe Inboxes::ImportImapJunkJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account, mailbox_sync_config: { 'mode' => 'active' }) }
  let(:service) { instance_double(Imap::JunkImportService) }

  it 'runs the Junk import for the channel' do
    allow(Imap::JunkImportService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_return({ status: 'completed' })

    described_class.perform_now(channel)

    expect(service).to have_received(:perform)
  end

  it 'retries with bounded jitter when another worker holds the per-inbox lease' do
    allow(Imap::JunkImportService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)
    allow(Imap::Lease).to receive(:retry_delay).with(0).and_return(7.0)

    expect { described_class.perform_now(channel) }
      .to have_enqueued_job(described_class).with(channel, 1, 1)
  end

  it 'stops retrying after the bounded lease retry limit' do
    allow(Imap::JunkImportService).to receive(:new).with(channel: channel, interval: 1).and_return(service)
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.perform_now(channel, 1, described_class::LEASE_RETRY_LIMIT) }
      .not_to have_enqueued_job(described_class)
  end

  it 'does not run for a channel with IMAP disabled' do
    allow(Imap::JunkImportService).to receive(:new)
    channel.update!(imap_enabled: false)

    described_class.perform_now(channel)

    expect(Imap::JunkImportService).not_to have_received(:new)
  end
end
