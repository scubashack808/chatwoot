require 'net/imap'

# Junk import for one inbox, enqueued by the existing */1 Inboxes::FetchImapEmailInboxesJob fan-out.
# It is its own job so a Junk failure cannot break inbound ingestion, and it takes the same
# per-inbox Imap::Lease, so it never holds a second connection against the same mailbox.
class Inboxes::ImportImapJunkJob < ApplicationJob
  queue_as :scheduled_jobs

  LEASE_RETRY_LIMIT = 4

  def perform(channel, interval = 1, lease_attempt = 0)
    return unless eligible?(channel)

    Imap::JunkImportService.new(channel: channel, interval: interval).perform
  rescue Imap::Lease::LeaseNotAcquiredError
    retry_after_contention(channel, interval, lease_attempt)
  rescue Imap::Lease::LeaseLostError => e
    log(channel, "lease lost mid-cycle: #{e.message}")
  rescue *ExceptionList::IMAP_EXCEPTIONS, *Inboxes::SyncImapSentJob::TRANSPORT_ERRORS => e
    log(channel, "#{e.class}: #{e.message}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  private

  def retry_after_contention(channel, interval, lease_attempt)
    if lease_attempt >= LEASE_RETRY_LIMIT
      log(channel, "lease remained busy after #{LEASE_RETRY_LIMIT} retries")
      return
    end

    delay = Imap::Lease.retry_delay(lease_attempt)
    log(channel, "lease busy, retrying in #{delay.round(2)} seconds")
    self.class.set(wait: delay).perform_later(channel, interval, lease_attempt + 1)
  end

  def eligible?(channel)
    channel.imap_enabled? && !channel.reauthorization_required?
  end

  def log(channel, detail)
    Rails.logger.info "[IMAP::JUNK_IMPORT] email channel #{channel.inbox.id}: #{detail}"
  end
end
