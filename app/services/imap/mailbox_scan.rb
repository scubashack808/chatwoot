# Imap::MailboxScan reads Message-IDs out of a set of mailboxes over a client that is already
# connected and already holding the per-inbox lease.
#
# It reports two things, and the second one is the reason this class exists: what it found, and
# whether each mailbox window can be trusted. A partial read and a deletion produce exactly the
# same index, so an index alone is never evidence that a message is gone. Callers that want to
# conclude absence must check the window first.
#
# Mailboxes are opened with EXAMINE, never SELECT, so a scan cannot set a flag or expunge
# anything, and only the Message-ID header is fetched, never a body.
class Imap::MailboxScan
  BATCH_SIZE = 500
  MESSAGE_ID_HEADER = 'BODY[HEADER.FIELDS (MESSAGE-ID)]'.freeze
  MESSAGE_ID_FETCH = 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]'.freeze

  Result = Struct.new(:index, :mailboxes, keyword_init: true) do
    def hits_for(message_id)
      index[message_id] || []
    end

    # True only when every requested mailbox was read end to end. Absence may only be concluded
    # from a conclusive scan.
    def conclusive?
      mailboxes.all? { |mailbox| mailbox[:complete] }
    end
  end

  # mailboxes is an array of [name, role] pairs; role is nil for a folder that carries no
  # mailbox role. max_messages bounds one mailbox: a mailbox above it is reported incomplete
  # rather than scanned, so a very large folder degrades into "cannot conclude" instead of into
  # an unbounded fetch.
  pattr_initialize [:client!, :session!, :mailboxes!, :max_messages]

  def perform
    index = Hash.new { |hash, key| hash[key] = [] }
    scanned = mailboxes.map { |mailbox, role| scan_mailbox(mailbox, role, index) }

    Result.new(index: index, mailboxes: scanned)
  end

  private

  def scan_mailbox(mailbox, role, index)
    session.command { |imap| imap.examine(mailbox) }
    context = { mailbox: mailbox, role: role, uidvalidity: Array(client.responses('UIDVALIDITY')).last }
    uids = Array(session.command { |imap| imap.uid_search(['ALL']) })

    return context.merge(message_count: uids.length, complete: false) if over_bound?(uids)

    collected = uids.each_slice(BATCH_SIZE).sum { |batch| collect_batch(batch, context, index) }
    context.merge(message_count: uids.length, complete: collected == uids.length)
  end

  def over_bound?(uids)
    max_messages.present? && uids.length > max_messages
  end

  # Returns how many fetch responses the server actually produced. A server that answers a UID
  # FETCH with fewer entries than the UID SEARCH reported has not shown us the whole mailbox.
  def collect_batch(batch, context, index)
    responses = Array(session.command { |imap| imap.uid_fetch(batch, fetch_attributes) })
    responses.each do |data|
      message_id = extract_message_id(data)
      next if message_id.blank?

      index[message_id] << context.merge(uid: data.attr['UID'], provider_id: data.attr['X-GM-MSGID']&.to_s)
    end

    responses.length
  end

  def fetch_attributes
    return ['UID', MESSAGE_ID_FETCH, 'X-GM-MSGID'] if gmail_extensions?

    ['UID', MESSAGE_ID_FETCH]
  end

  def gmail_extensions?
    return @gmail_extensions if defined?(@gmail_extensions)

    @gmail_extensions = client.capabilities.include?('X-GM-EXT-1')
  rescue StandardError
    @gmail_extensions = false
  end

  def extract_message_id(data)
    raw = data.attr[MESSAGE_ID_HEADER]
    return nil if raw.blank?

    Mail.read_from_string(raw).message_id
  end
end
