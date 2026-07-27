# Imap::MailboxProbe answers one narrow question as cheaply as IMAP allows: are the exact messages
# Chatwoot tracks still at the exact coordinates it recorded for them?
#
# It exists because of an asymmetry. Enumerating folders to build a Message-ID index is bounded by
# the amount of mail ON THE SERVER, while this is bounded by the amount of mail CHATWOOT TRACKS. A
# real mailbox holds years of mail Chatwoot never imported, so an enumerating cycle spends nearly
# all of its work reading headers of messages it does not care about, and it does that whether or
# not anything changed. Measured against Dovecot at 3,000 server messages with 400 tracked: 2
# commands and 400 UIDs here, against 22 commands and 3,000 header fetches for the enumeration.
#
# It cannot conclude absence and it never tries. A UID that did not come back has left the mailbox
# it was recorded in, and a move and a deletion look identical from here. Deciding between them
# requires reading somewhere end to end, which is Imap::MailboxScan's job. The probe's only purpose
# is to decide whether that scan has to run at all.
#
# Mailboxes are opened with EXAMINE, never SELECT, and only UIDs are fetched, so this sets no flag,
# expunges nothing, and reads no message content. It is safe in `observe` mode.
class Imap::MailboxProbe
  BATCH_SIZE = 500

  Result = Struct.new(:vanished, :generations_changed, :mailboxes_probed, :tracked_count, keyword_init: true) do
    # True when every tracked identity was found exactly where it was recorded, in a mailbox whose
    # UIDVALIDITY still matches. Nothing has happened on the server that Chatwoot needs to react
    # to, so the expensive scan can be skipped entirely for this cycle.
    def settled?
      vanished.empty? && generations_changed.empty?
    end
  end

  # locations is { mailbox_name => { uid => uidvalidity } }, built straight from the stored
  # identities, so the probe asks about exactly the coordinates Chatwoot believes in and nothing
  # else.
  pattr_initialize [:client!, :session!, :locations!]

  def perform
    vanished = []
    generations_changed = []

    locations.each { |mailbox, uid_map| probe_mailbox(mailbox, uid_map, vanished, generations_changed) }

    Result.new(
      vanished: vanished, generations_changed: generations_changed,
      mailboxes_probed: locations.keys, tracked_count: locations.values.sum(&:size)
    )
  end

  private

  def probe_mailbox(mailbox, uid_map, vanished, generations_changed)
    session.command { |imap| imap.examine(mailbox) }
    return generations_changed << mailbox if generation_changed?(uid_map)

    missing_uids(uid_map.keys).each { |uid| vanished << { mailbox: mailbox, uid: uid } }
  rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError
    # The mailbox Chatwoot recorded no longer exists or cannot be examined. Every identity filed
    # there needs re-resolving and only a full scan can do that, so escalate rather than treating
    # an unreadable folder as a mailbox full of deletions.
    generations_changed << mailbox
  end

  # A UIDVALIDITY change voids every UID in the mailbox at once, so the stored coordinates are
  # meaningless and their absence proves nothing. Escalate instead of reporting mass deletion.
  def generation_changed?(uid_map)
    observed = Array(client.responses('UIDVALIDITY')).last
    return true if observed.nil?

    uid_map.values.compact.uniq.any? { |recorded| recorded.to_i != observed.to_i }
  end

  # Asks only whether these exact UIDs still exist. No headers, no bodies, and nothing about mail
  # Chatwoot has never imported.
  def missing_uids(uids)
    present = uids.each_slice(BATCH_SIZE).flat_map do |batch|
      Array(session.command { |imap| imap.uid_fetch(batch, ['UID']) }).map { |data| data.attr['UID'] }
    end

    uids - present
  end
end
