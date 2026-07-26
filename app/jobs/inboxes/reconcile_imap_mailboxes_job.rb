# Fans reconciliation out across every email inbox that is allowed to run it. Both dark gates are
# checked here so that an installation with the feature off enqueues nothing at all; the service
# re-checks them anyway, because the flag can change between enqueue and execution.
class Inboxes::ReconcileImapMailboxesJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Inbox.where(channel_type: 'Channel::Email').find_each(batch_size: 100) do |inbox|
      ::Inboxes::ReconcileImapMailboxJob.perform_later(inbox.channel) if should_reconcile?(inbox)
    end
  end

  private

  def should_reconcile?(inbox)
    return false if inbox.account.suspended?
    return false unless inbox.channel.imap_enabled?
    return false if inbox.channel.reauthorization_required?
    return false unless inbox.account.feature_enabled?('email_mailbox_actions')

    !inbox.channel.mailbox_sync.off?
  end
end
