require 'net/imap'

# Runs one reconciliation pass for one email channel. It is deliberately a separate job from the
# fetch cycle even though both are now enqueued by the same scheduled trigger: reconciliation takes
# the same per-inbox lease, so it must not run inside a fetch, and a reconciliation failure must
# never be able to break ingestion.
#
# This job owns the operational half of the pass. The service decides what is true about the
# mailbox; the job is what makes that visible. Reconciliation can degrade into concluding nothing
# (a folder above the scan bound, a folder that cannot be examined, a lease it never wins) and
# every one of those failure modes is silent by nature: an inbox that has quietly stopped
# reconciling looks exactly like an inbox where nothing has moved.
class Inboxes::ReconcileImapMailboxJob < ApplicationJob
  queue_as :scheduled_jobs

  # The execution plan's objective is a successful cycle every two minutes. Five minutes without
  # one means something is wrong rather than merely contended.
  STALL_THRESHOLD = 5.minutes

  def perform(channel)
    report = Imap::MailboxReconciliationService.new(channel: channel).perform
    handle(channel, report)
    report
  rescue StandardError => e
    log_failure(channel, e)
    warn_if_stalled(channel)
  end

  private

  # Contention is not a failure: another worker holds this mailbox, so the pass defers to the next
  # cycle rather than opening a second connection. Sustained contention IS a problem, which is why
  # every branch here falls through to the stall check.
  def log_failure(channel, error)
    inbox_id = channel.inbox.id

    case error
    when Imap::Lease::LeaseNotAcquiredError
      Rails.logger.info "[IMAP] Lease busy for reconciliation - #{inbox_id}, deferring to the next cycle."
    when Imap::Lease::LeaseLostError
      Rails.logger.warn "[IMAP] Lease lost mid-reconciliation for #{inbox_id} : #{error.message}"
    when *ExceptionList::IMAP_EXCEPTIONS
      Rails.logger.error "Authorization error during reconciliation for email channel - #{inbox_id} : #{error.message}"
    when IOError, OpenSSL::SSL::SSLError, Net::IMAP::Error
      Rails.logger.error "Error during reconciliation for email channel - #{inbox_id} : #{error.message}"
    else
      ChatwootExceptionTracker.new(error, account: channel.account).capture_exception
    end
  end

  # A dark inbox is skipped by design and is not stalled, so it neither records success nor warns.
  def handle(channel, report)
    return if report[:status] == 'skipped'

    warn_about_untrustworthy_windows(channel, report)
    report[:conclusive] ? record_success(channel) : warn_if_stalled(channel)
  end

  # A scan that could not read a folder end to end cannot conclude that anything is absent, and
  # because that verdict is all-or-nothing across the inbox, one oversized folder stops every
  # absence conclusion for the whole inbox. Naming the folder and the bound is the difference
  # between a diagnosable stop and an invisible one.
  def warn_about_untrustworthy_windows(channel, report)
    return if report[:conclusive]

    Array(report[:mailboxes_scanned]).reject { |mailbox| mailbox[:complete] }.each do |mailbox|
      Rails.logger.warn(
        "[IMAP] Reconciliation could not read #{mailbox[:mailbox].inspect} end to end for inbox " \
        "#{channel.inbox.id} (#{mailbox[:message_count]} messages, bound " \
        "#{Imap::MailboxReconciliationService::MAX_MESSAGES_PER_MAILBOX}). No absence will be concluded " \
        'for this inbox until it can be read completely.'
      )
    end
  end

  def record_success(channel)
    clock(channel).record
  end

  # First observation seeds the clock rather than warning, so a newly managed inbox does not report
  # a stall it never had.
  def warn_if_stalled(channel)
    stalled_for = clock(channel).elapsed
    return record_success(channel) if stalled_for.nil?
    return if stalled_for < STALL_THRESHOLD.to_i

    Rails.logger.warn(
      "[IMAP] Inbox #{channel.inbox.id} has not completed a reconciliation cycle for " \
      "#{stalled_for / 60} minutes. External mailbox changes are not being reflected."
    )
  end

  def clock(channel)
    Imap::CycleClock.new(inbox: channel.inbox, key_template: Redis::RedisKeys::IMAP_RECONCILED_AT)
  end
end
