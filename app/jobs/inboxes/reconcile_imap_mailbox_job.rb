require 'net/imap'

# Runs one reconciliation pass for one email channel. It is deliberately a separate job from the
# fetch cycle: reconciliation takes the same per-inbox lease, so it must not run inside a fetch,
# and a reconciliation failure must never be able to break ingestion.
class Inboxes::ReconcileImapMailboxJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(channel)
    Imap::MailboxReconciliationService.new(channel: channel).perform
  rescue Imap::Lease::LeaseNotAcquiredError
    # Contention is not a failure. Another worker holds this mailbox, so the pass defers to the
    # next cycle rather than opening a second connection.
    Rails.logger.info "[IMAP] Lease busy for reconciliation - #{channel.inbox.id}, deferring to the next cycle."
  rescue Imap::Lease::LeaseLostError => e
    Rails.logger.warn "[IMAP] Lease lost mid-reconciliation for #{channel.inbox.id} : #{e.message}"
  rescue *ExceptionList::IMAP_EXCEPTIONS => e
    Rails.logger.error "Authorization error during reconciliation for email channel - #{channel.inbox.id} : #{e.message}"
  rescue IOError, OpenSSL::SSL::SSLError, Net::IMAP::Error => e
    Rails.logger.error "Error during reconciliation for email channel - #{channel.inbox.id} : #{e.message}"
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end
end
