require 'net/imap'

# Sent synchronisation for one inbox, enqueued by the existing */1 Inboxes::FetchImapEmailInboxesJob
# fan-out. It is its own job rather than a step inside the fetch so that a Sent failure cannot break
# inbound ingestion, and it takes the same per-inbox Imap::Lease, so the two never hold two
# connections against the same mailbox at once.
class Inboxes::SyncImapSentJob < ApplicationJob
  queue_as :scheduled_jobs

  TRANSPORT_ERRORS = [
    IOError, OpenSSL::SSL::SSLError, Timeout::Error,
    Net::IMAP::NoResponseError, Net::IMAP::BadResponseError, Net::IMAP::InvalidResponseError,
    Net::IMAP::ResponseParseError, Net::IMAP::ResponseReadError, Net::IMAP::ResponseTooLargeError
  ].freeze

  def perform(channel, interval = 1)
    return unless eligible?(channel)

    Imap::SentSyncService.new(channel: channel, interval: interval).perform
  rescue Imap::Lease::LeaseNotAcquiredError
    # Contention is not a failure. Ingestion holds the mailbox this minute, so Sent work defers to
    # the next cycle rather than opening a second connection as a fallback.
    log(channel, 'lease busy, deferring to the next cycle')
  rescue Imap::Lease::LeaseLostError => e
    log(channel, "lease lost mid-cycle: #{e.message}")
  rescue *ExceptionList::IMAP_EXCEPTIONS, *TRANSPORT_ERRORS => e
    log(channel, "#{e.class}: #{e.message}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  private

  def eligible?(channel)
    channel.imap_enabled? && !channel.reauthorization_required?
  end

  def log(channel, detail)
    Rails.logger.info "[IMAP::SENT_SYNC] email channel #{channel.inbox.id}: #{detail}"
  end
end
