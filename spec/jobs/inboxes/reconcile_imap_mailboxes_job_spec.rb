require 'rails_helper'

RSpec.describe Inboxes::ReconcileImapMailboxesJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }

  # A second, always-eligible inbox on its own account. Every "enqueues nothing" example below
  # asserts against it too, so a fan-out that simply never ran cannot satisfy them.
  let(:other_account) { create(:account) }
  let(:other_channel) { create(:channel_email, :imap_email, account: other_account) }

  before do
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'observe' })
    other_account.enable_features!(:email_mailbox_actions)
    other_channel.update!(mailbox_sync_config: { 'mode' => 'observe' })
  end

  it 'enqueues the job on the scheduled jobs queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'fans out one reconciliation job per eligible email inbox' do
    expect { described_class.perform_now }
      .to have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(channel)
      .and have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(other_channel)
  end

  it 'enqueues nothing for an account whose feature is disabled' do
    account.disable_features!(:email_mailbox_actions)

    expect { described_class.perform_now }
      .to have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(other_channel).exactly(:once)
    expect(enqueued_channels).not_to include(channel)
  end

  it 'enqueues nothing for an inbox whose mailbox sync mode is off' do
    channel.update!(mailbox_sync_config: { 'mode' => 'off' })

    expect { described_class.perform_now }
      .to have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(other_channel).exactly(:once)
    expect(enqueued_channels).not_to include(channel)
  end

  it 'enqueues nothing for a suspended account' do
    account.update!(status: :suspended)

    expect { described_class.perform_now }
      .to have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(other_channel).exactly(:once)
    expect(enqueued_channels).not_to include(channel)
  end

  it 'enqueues nothing for a channel that needs reauthorization' do
    channel.prompt_reauthorization!

    expect { described_class.perform_now }
      .to have_enqueued_job(Inboxes::ReconcileImapMailboxJob).with(other_channel).exactly(:once)
    expect(enqueued_channels).not_to include(channel)
  end

  it 'enqueues nothing for a non email inbox' do
    create(:channel_widget, account: account)

    described_class.perform_now

    expect(enqueued_channels).to contain_exactly(channel, other_channel)
  end

  def enqueued_channels
    ActiveJob::Base.queue_adapter.enqueued_jobs
                   .select { |job| job[:job] == Inboxes::ReconcileImapMailboxJob }
                   .map { |job| ActiveJob::Arguments.deserialize(job[:args]).first }
  end
end
