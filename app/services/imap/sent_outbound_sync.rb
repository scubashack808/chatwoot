# M05: put Chatwoot sends in the real Sent folder, without duplicates.
#
# Email::SendOnEmailService already stores the RFC Message-ID the mailer produced on the outgoing
# message's source_id, and ConversationReplyMailer derives that id deterministically from the
# conversation UUID and the message id. Those two facts are what make this idempotent without
# storing a raw body anywhere: every attempt searches Sent for that exact Message-ID first, and a
# retry re-renders a message carrying the same id, so a copy that already landed is found and
# attached instead of appended a second time.
class Imap::SentOutboundSync
  # How far back a message stays eligible for retry. A Sent-sync outage retries every cycle inside
  # this window and then stops, rather than accumulating unbounded work forever.
  RETRY_WINDOW = 7.days
  MAX_PER_CYCLE = 100

  # A retry that keeps failing the same way is not going to start working inside the retry window,
  # and every attempt is an APPEND that may or may not have landed. After this many consecutive
  # failures the message stops being appended and says so, instead of retrying every minute for
  # seven days.
  MAX_APPEND_ATTEMPTS = 5

  # Rails' JSON store coder can persist this jsonb column as either a JSON object or a JSON string.
  # Extracting the root as text and casting it normalises both, exactly as Imap::MailboxRoleFilter
  # does for the read surface.
  NOT_TERMINAL_SQL = <<~SQL.squish.freeze
    COALESCE((messages.external_source_ids #>> '{}')::jsonb #>> '{imap,sent_sync,state}', '')
      NOT IN (#{Imap::SentSyncState::TERMINAL.map { |state| "'#{state}'" }.join(', ')})
  SQL

  def initialize(channel:, sent_mailbox:)
    @channel = channel
    @sent_mailbox = sent_mailbox
    @counts = Hash.new(0)
  end

  def perform
    candidates.each { |message| synchronize(message) }
    @counts.merge(candidates: candidates.length)
  end

  # Outgoing email that was actually delivered (source_id present), is not a private note, and is
  # not already recorded as living in Sent. The synced test is done in SQL so a busy inbox does not
  # load a week of outgoing messages into memory to discard them.
  def candidates
    @candidates ||= channel.inbox.messages
                           .where(message_type: :outgoing, private: false)
                           .where.not(source_id: nil)
                           .where(created_at: RETRY_WINDOW.ago..)
                           .where(NOT_TERMINAL_SQL)
                           .limit(MAX_PER_CYCLE)
                           .to_a
  end

  private

  attr_reader :channel, :sent_mailbox

  def synchronize(message)
    existing = sent_mailbox.search_message_id(message.source_id)

    return attach(message, existing.first) if existing.one?
    return record_conflict(message, existing) if existing.many?

    sent_mailbox.append_allowed? ? append(message) : await_provider_copy(message)
  rescue Imap::Lease::LeaseLostError
    # Contention is not a per-message data failure. Imap::Session raises this before every command
    # once the lease is gone, so swallowing it here would mark the whole remaining batch failed and
    # inflate every attempt count for something that was never about these messages. The job
    # already has a handler for it. Same shape as Imap::MailboxOperationExecutor.
    raise
  rescue StandardError => e
    record_failure(message, e)
  end

  def attach(message, uid)
    write(message, state: Imap::SentSyncState::SYNCED, uidvalidity: sent_mailbox.uidvalidity, uid: uid)
    @counts[:attached] += 1
  end

  def append(message)
    return record_attempts_exhausted(message) if attempts_exhausted?(message)

    mail = rendered_mail(message)
    return record_message_id_mismatch(message, mail.message_id) unless mail.message_id == message.source_id

    location = sent_mailbox.append(
      source: mail.encoded,
      message_id: message.source_id,
      internal_date: message.created_at.to_time
    )
    return record_failure(message, 'APPEND was accepted but the copy could not be located') if location.nil?

    write(message, state: Imap::SentSyncState::SYNCED, uidvalidity: location[:uidvalidity], uid: location[:uid])
    @counts[:appended] += 1
  end

  # The same renderer and the same entry point that delivered the message. It is rendered, never
  # delivered: ActionMailer::MessageDelivery#message builds the mail without handing it to a
  # delivery method, so this cannot send a second copy to the contact. The Mail object is returned
  # rather than its encoding, so the Message-ID can be read off the exact object about to be
  # appended instead of re-parsing what was encoded.
  def rendered_mail(message)
    ConversationReplyMailer.with(account: message.account).email_reply(message).message
  end

  # Everything about not duplicating rests on the premise that the source being appended carries
  # the Message-ID the search looks for. Two inputs to that deterministic id, the account's
  # inbound email domain and the channel address, can change after the message was delivered.
  # When they do, the search finds nothing, the append lands a copy under a new id, and the next
  # cycle does it again. So the premise is checked rather than assumed, and a mismatch is
  # abandoned rather than retried: retrying is precisely what would duplicate.
  def record_message_id_mismatch(message, rendered_id)
    record_state(message, Imap::SentSyncState::ABANDONED,
                 error: "rendered Message-ID #{rendered_id.inspect} does not match the delivered #{message.source_id.inspect}")
    @counts[:message_id_mismatch] += 1
  end

  # A consecutive-failure cap. Without it a message that fails the same way every time is appended
  # once a minute for the whole seven-day retry window, and each of those attempts may have left a
  # copy on the server.
  def attempts_exhausted?(message)
    state = message.imap_sent_sync
    state.present? && state.state == Imap::SentSyncState::FAILED && state.attempts >= MAX_APPEND_ATTEMPTS
  end

  def record_attempts_exhausted(message)
    record_state(message, Imap::SentSyncState::ABANDONED,
                 error: "gave up after #{MAX_APPEND_ATTEMPTS} consecutive failed attempts")
    @counts[:attempts_exhausted] += 1
  end

  def await_provider_copy(message)
    record_state(message, Imap::SentSyncState::AWAITING_PROVIDER_COPY)
    @counts[:awaiting_provider_copy] += 1
  end

  def record_conflict(message, uids)
    record_state(message, Imap::SentSyncState::CONFLICT, error: "#{uids.length} copies already match this Message-ID")
    @counts[:conflict] += 1
  end

  def record_failure(message, error)
    record_state(message, Imap::SentSyncState::FAILED, error: error)
    @counts[:failed] += 1
  end

  def record_state(message, state, error: nil)
    message.write_imap_sent_sync!(
      Imap::SentSyncState.build(state: state, attempts: message.imap_sent_sync&.attempts.to_i + 1, error: error)
    )
  end

  def write(message, state:, uidvalidity:, uid:)
    message.write_imap_sent_sync!(
      Imap::SentSyncState.build(state: state, attempts: message.imap_sent_sync&.attempts.to_i + 1),
      identity: Imap::MessageIdentity.build(mailbox: sent_mailbox.mailbox, uidvalidity: uidvalidity, uid: uid, roles: ['sent'])
    )
  end
end
