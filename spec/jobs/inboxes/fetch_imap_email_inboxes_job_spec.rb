require 'rails_helper'

RSpec.describe Inboxes::FetchImapEmailInboxesJob do
  let(:account) { create(:account) }
  let(:suspended_account) { create(:account, status: 'suspended') }
  let(:premium_account) { create(:account, custom_attributes: { plan_name: 'Startups' }) }

  let(:imap_email_channel) do
    create(:channel_email, imap_enabled: true, account: account)
  end

  let(:imap_email_channel_suspended) do
    create(:channel_email, imap_enabled: true, account: suspended_account)
  end

  let(:disabled_imap_channel) do
    create(:channel_email, imap_enabled: false, account: account)
  end

  let(:reauth_required_channel) do
    create(:channel_email, imap_enabled: true, account: account)
  end

  let(:premium_imap_channel) do
    create(:channel_email, imap_enabled: true, account: premium_account)
  end

  before do
    reauth_required_channel.prompt_reauthorization!
    premium_account.custom_attributes['plan_name'] = 'Startups'
  end

  it 'enqueues the job' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class)
      .on_queue('scheduled_jobs')
  end

  context 'when called' do
    it 'fetches emails only for active accounts with imap enabled' do
      # Should call perform_later only once for the active, imap-enabled inbox
      expect(Inboxes::FetchImapEmailsJob).to receive(:perform_later).with(imap_email_channel).once

      # Should not call for suspended account or disabled IMAP channels
      expect(Inboxes::FetchImapEmailsJob).not_to receive(:perform_later).with(imap_email_channel_suspended)
      expect(Inboxes::FetchImapEmailsJob).not_to receive(:perform_later).with(disabled_imap_channel)

      described_class.perform_now
    end

    it 'skips suspended accounts' do
      expect(Inboxes::FetchImapEmailsJob).not_to receive(:perform_later).with(imap_email_channel_suspended)

      described_class.perform_now
    end

    it 'skips disabled imap channels' do
      expect(Inboxes::FetchImapEmailsJob).not_to receive(:perform_later).with(disabled_imap_channel)

      described_class.perform_now
    end

    it 'skips channels requiring reauthorization' do
      expect(Inboxes::FetchImapEmailsJob).not_to receive(:perform_later).with(reauth_required_channel)

      described_class.perform_now
    end
  end

  # Plan section 9's rule is the pattern for all mail work in this stack: one scheduler, the
  # existing */1 trigger, the same per-inbox lease. Sent sync rides this fan-out as its own
  # isolated job, so a Sent failure cannot break ingestion and no second cron entry is added.
  context 'with Sent synchronization' do
    it 'enqueues Sent sync from the same fan-out, for the same eligible channels' do
      allow(Inboxes::FetchImapEmailsJob).to receive(:perform_later)
      expect(Inboxes::SyncImapSentJob).to receive(:perform_later).with(imap_email_channel).once
      expect(Inboxes::SyncImapSentJob).not_to receive(:perform_later).with(imap_email_channel_suspended)
      expect(Inboxes::SyncImapSentJob).not_to receive(:perform_later).with(disabled_imap_channel)
      expect(Inboxes::SyncImapSentJob).not_to receive(:perform_later).with(reauth_required_channel)

      described_class.perform_now
    end

    it 'adds no second scheduler entry: the IMAP trigger set is unchanged from base' do
      schedule = YAML.load_file(Rails.root.join('config/schedule.yml'))
      imap_triggers = schedule.select { |_name, entry| entry['class'].to_s.start_with?('Inboxes::') }

      expect(imap_triggers.keys).to eq(['trigger_imap_email_inboxes_job'])
      expect(imap_triggers.values.map { |entry| entry['cron'] }).to eq(['*/1 * * * *'])
    end
  end
end
