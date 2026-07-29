require 'net/imap'

# Sent synchronisation for one inbox, enqueued by the existing */1 Inboxes::FetchImapEmailInboxesJob
# fan-out. It is its own job rather than a step inside the fetch so that a Sent failure cannot break
# inbound ingestion, and it takes the same per-inbox Imap::Lease, so the two never hold two
# connections against the same mailbox at once.
class Inboxes::SyncImapSentJob < ApplicationJob
  queue_as :scheduled_jobs

  LEASE_RETRY_LIMIT = 4

  TRANSPORT_ERRORS = [
    IOError, OpenSSL::SSL::SSLError, Timeout::Error,
    Net::IMAP::NoResponseError, Net::IMAP::BadResponseError, Net::IMAP::InvalidResponseError,
    Net::IMAP::ResponseParseError, Net::IMAP::ResponseReadError, Net::IMAP::ResponseTooLargeError
  ].freeze

  def perform(channel, interval = 1, lease_attempt = 0)
    return unless eligible?(channel)

    Imap::SentSyncService.new(channel: channel, interval: interval).perform
  rescue Imap::Lease::LeaseNotAcquiredError
    retry_after_contention(channel, interval, lease_attempt)
  rescue Imap::Lease::LeaseLostError => e
    log(channel, "lease lost mid-cycle: #{e.message}")
  rescue *ExceptionList::IMAP_EXCEPTIONS, *TRANSPORT_ERRORS => e
    log(channel, "#{e.class}: #{e.message}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  private

  # Repeating the same immediate fan-out on the next minute can give ingestion the lease forever.
  # Retry with the lease's existing bounded jitter so this cycle can run after ingestion releases
  # it without ever opening a concurrent connection.
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
    Rails.logger.info "[IMAP::SENT_SYNC] email channel #{channel.inbox.id}: #{detail}"
  end
end
