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

  # Rails' JSON store coder can persist this jsonb column as either a JSON object or a JSON string.
  # Extracting the root as text and casting it normalises both, exactly as Imap::MailboxRoleFilter
  # does for the read surface.
  NOT_SYNCED_SQL = <<~SQL.squish.freeze
    COALESCE((messages.external_source_ids #>> '{}')::jsonb #>> '{imap,sent_sync,state}', '') != 'synced'
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
                           .where(NOT_SYNCED_SQL)
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
  rescue StandardError => e
    record_failure(message, e)
  end

  def attach(message, uid)
    write(message, state: Imap::SentSyncState::SYNCED, uidvalidity: sent_mailbox.uidvalidity, uid: uid)
    @counts[:attached] += 1
  end

  def append(message)
    location = sent_mailbox.append(
      source: rendered_source(message),
      message_id: message.source_id,
      internal_date: message.created_at.to_time
    )
    return record_failure(message, 'APPEND was accepted but the copy could not be located') if location.nil?

    write(message, state: Imap::SentSyncState::SYNCED, uidvalidity: location[:uidvalidity], uid: location[:uid])
    @counts[:appended] += 1
  end

  # The same renderer and the same entry point that delivered the message. It is rendered, never
  # delivered: ActionMailer::MessageDelivery#message builds the mail without handing it to a
  # delivery method, so this cannot send a second copy to the contact.
  def rendered_source(message)
    ConversationReplyMailer.with(account: message.account).email_reply(message).message.encoded
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
