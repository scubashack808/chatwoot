class Inboxes::FetchImapEmailInboxesJob < ApplicationJob
  queue_as :scheduled_jobs
  include BillingHelper

  def perform
    email_inboxes = Inbox.where(channel_type: 'Channel::Email')
    email_inboxes.find_each(batch_size: 100) do |inbox|
      next unless should_fetch_emails?(inbox)

      ::Inboxes::FetchImapEmailsJob.perform_later(inbox.channel)
      ::Inboxes::ReconcileImapMailboxJob.perform_later(inbox.channel) if should_reconcile?(inbox)
    end
  end

  private

  # Reconciliation rides this trigger rather than owning a second scheduler, so the reverse path
  # runs at the same cadence as ingestion. It stays a separate job: both take the same per-inbox
  # lease, so they must not nest, and a reconciliation failure must never break ingestion. The
  # loser of that lease defers to the next cycle, which at this cadence costs a minute.
  #
  # This is a strictly narrower gate than should_fetch_emails?, which has already passed here.
  def should_reconcile?(inbox)
    return false unless inbox.account.feature_enabled?('email_mailbox_actions')

    !inbox.channel.mailbox_sync.off?
  end

  def should_fetch_emails?(inbox)
    return false if inbox.account.suspended?
    return false unless inbox.channel.imap_enabled
    return false if inbox.channel.reauthorization_required?

    return true unless ChatwootApp.chatwoot_cloud?
    return false if default_plan?(inbox.account)

    true
  end
end
