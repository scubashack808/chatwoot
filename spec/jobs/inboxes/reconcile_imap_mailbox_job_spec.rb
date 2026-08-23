require 'rails_helper'

RSpec.describe Inboxes::ReconcileImapMailboxJob do
  subject(:job) { described_class.perform_later(channel) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:service) { instance_double(Imap::MailboxReconciliationService) }

  before do
    allow(Imap::MailboxReconciliationService).to receive(:new).with(channel: channel).and_return(service)
  end

  it 'enqueues the job on the scheduled jobs queue' do
    expect { job }.to have_enqueued_job(described_class).on_queue('scheduled_jobs').with(channel)
  end

  it 'runs one reconciliation pass for the channel' do
    allow(service).to receive(:perform)

    described_class.perform_now(channel)

    expect(service).to have_received(:perform)
  end

  it 'retries with bounded jitter when another worker already holds the mailbox lease' do
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)
    allow(Imap::Lease).to receive(:retry_delay).with(0).and_return(7.0)

    expect { described_class.perform_now(channel) }
      .to have_enqueued_job(described_class).with(channel, 1)
    expect(service).to have_received(:perform)
  end

  it 'stops retrying after the bounded lease retry limit' do
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.perform_now(channel, described_class::LEASE_RETRY_LIMIT) }
      .not_to have_enqueued_job(described_class)
  end

  it 'does not report a lost lease as an application exception' do
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseLostError)
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

    described_class.perform_now(channel)

    expect(service).to have_received(:perform)
    expect(tracker).not_to have_received(:capture_exception)
  end

  it 'captures an unexpected failure instead of crashing the cycle' do
    allow(service).to receive(:perform).and_raise(StandardError, 'boom')
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

    described_class.perform_now(channel)

    expect(tracker).to have_received(:capture_exception)
  end
end
