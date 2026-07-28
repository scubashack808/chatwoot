class Inboxes::FetchImapEmailInboxesJob < ApplicationJob
  queue_as :scheduled_jobs
  include BillingHelper

  def perform
    email_inboxes = Inbox.where(channel_type: 'Channel::Email')
    email_inboxes.find_each(batch_size: 100) do |inbox|
      next unless should_fetch_emails?(inbox)

      ::Inboxes::FetchImapEmailsJob.perform_later(inbox.channel)
      ::Inboxes::ReconcileImapMailboxJob.perform_later(inbox.channel) if should_reconcile?(inbox)
      # Sent synchronisation rides this one existing trigger rather than adding a second scheduler.
      # It is a separate job so a Sent failure cannot break ingestion, and it takes the same
      # per-inbox lease, so the jobs on this fan-out defer to each other instead of opening extra
      # connections.
      ::Inboxes::SyncImapSentJob.perform_later(inbox.channel) if should_sync_sent?(inbox)
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

  # Sent sync is dark on the same two gates as reconciliation. It is a separate predicate rather
  # than a shared one because the two jobs answer to different halves of the config and will
  # diverge (Sent has its own sent_mode), and because reusing reconciliation's predicate would
  # make a later change to one silently change the other.
  #
  # Gating at enqueue time rather than only inside the job is what keeps a dark feature free: with
  # either gate off, no job is queued at all, instead of one no-op job per email inbox per minute.
  def should_sync_sent?(inbox)
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
