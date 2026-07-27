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

  it 'defers politely when another worker already holds the mailbox lease' do
    allow(service).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.perform_now(channel) }.not_to raise_error
    expect(service).to have_received(:perform)
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
