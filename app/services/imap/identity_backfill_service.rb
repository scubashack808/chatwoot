# Imap::IdentityBackfillService attaches server identity to messages Chatwoot imported before it
# recorded UIDs.
#
# It is deliberately two-phase and never runs on its own. A dry run reports what it would do, per
# inbox, split into exact, ambiguous, missing, stale and already-recorded. Only an explicitly
# invoked apply writes anything, and it records exact matches only.
#
# Mailboxes are opened with EXAMINE, not SELECT, so neither phase can mutate the server: no flags
# are set and nothing is expunged. Message bodies are never fetched; only the Message-ID header.
#
# Matching is by RFC Message-ID, which is a recovery hint rather than mutation authority. A
# Message-ID that appears in more than one place is ambiguous and is never recorded, because a
# generic IMAP server gives no way to tell the copies apart.
class Imap::IdentityBackfillService
  pattr_initialize [:channel!]

  def dry_run
    scan
  end

  # Records identity for exact matches only. Safe to run repeatedly: a message whose stored
  # identity already matches the server is skipped, so a second run reports zero applied.
  def apply
    report = scan
    applied = report[:exact].count { |match| record_identity(match) }

    report.merge(applied: applied)
  end

  private

  def scan
    classify(read_server)
  end

  # One connection, one lease, for the whole scan. The reading itself is Imap::MailboxScan, which
  # this shares with reconciliation; the backfill sets no size bound, so its windows are the same
  # unbounded full-mailbox reads they have always been.
  def read_server
    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      Imap::MailboxScan.new(
        client: client, session: session, mailboxes: mailboxes_to_scan(client, session), max_messages: nil
      ).perform
    end
  end

  # INBOX is always scanned. Every other mailbox comes from the inbox's own resolved roles, so a
  # role that is unavailable or ambiguous is simply not scanned rather than guessed at.
  def mailboxes_to_scan(client, session)
    listing = session.command { client.list('', '*') }
    result = Imap::FolderDiscoveryService.result_for(folders: listing, config: channel.mailbox_sync)

    role_mailboxes = Imap::FolderDiscoveryService::ROLE_ATTRIBUTES.keys.filter_map do |role|
      resolved = result.for_role(role)
      [resolved.selected, role] if resolved&.available?
    end

    ([[Imap::MailboxSyncConfig::RESTORE_TARGET, 'inbox']] + role_mailboxes).uniq { |mailbox, _role| mailbox }
  end

  def classify(scan)
    report = empty_report(scan.mailboxes)

    candidates.find_each do |message|
      report[:candidates] += 1
      classify_message(message, scan.hits_for(message.source_id), report)
    end

    report
  end

  def classify_message(message, hits, report)
    return report[:missing] << { chatwoot_message_id: message.id, message_id: message.source_id } if hits.blank?

    locations = collapse_locations(hits)
    return report[:ambiguous] << ambiguous_entry(message, locations) if locations.length > 1

    bucket_for(message, locations.first, report) << match_entry(message, locations.first)
  end

  # Gmail exposes one message through several mailboxes at once via labels. Hits sharing a
  # provider-stable id are therefore one message in several places, not several messages.
  def collapse_locations(hits)
    provider_ids = hits.filter_map { |hit| hit[:provider_id] }.uniq
    return [hits.first.merge(locations: hits)] if provider_ids.length == 1 && hits.length > 1

    hits
  end

  def bucket_for(message, hit, report)
    stored = message.imap_identity
    return report[:exact] if stored.nil?

    if stored.stale_for?(mailbox: hit[:mailbox], uidvalidity: hit[:uidvalidity])
      report[:stale] << stale_entry(message, stored, hit)
      return report[:exact]
    end

    return report[:already_recorded] if stored.uid == hit[:uid] && stored.mailbox == hit[:mailbox]

    report[:exact]
  end

  def match_entry(message, hit)
    {
      chatwoot_message_id: message.id, message_id: message.source_id,
      mailbox: hit[:mailbox], role: hit[:role], uidvalidity: hit[:uidvalidity],
      uid: hit[:uid], provider_id: hit[:provider_id], locations: hit[:locations]
    }
  end

  def ambiguous_entry(message, locations)
    {
      chatwoot_message_id: message.id, message_id: message.source_id,
      locations: locations.map { |hit| hit.slice(:mailbox, :uid, :uidvalidity) }
    }
  end

  def stale_entry(message, stored, hit)
    {
      chatwoot_message_id: message.id, message_id: message.source_id, mailbox: hit[:mailbox],
      stored_uidvalidity: stored.uidvalidity, stored_uid: stored.uid,
      server_uidvalidity: hit[:uidvalidity], server_uid: hit[:uid]
    }
  end

  def empty_report(mailboxes)
    {
      inbox_id: channel.inbox.id, inbox_name: channel.inbox.name, email: channel.email,
      mailboxes_scanned: mailboxes, candidates: 0,
      exact: [], ambiguous: [], missing: [], stale: [], already_recorded: []
    }
  end

  # Only incoming messages carrying an RFC Message-ID can be matched at all.
  def candidates
    channel.inbox.messages.where(message_type: :incoming).where.not(source_id: [nil, ''])
  end

  def record_identity(match)
    message = channel.inbox.messages.find_by(id: match[:chatwoot_message_id])
    return false if message.nil?

    identity = identity_for(match)
    return false if unchanged?(message.imap_identity, identity)

    message.write_imap_identity!(identity)
    true
  end

  def identity_for(match)
    identity = Imap::MessageIdentity.build(
      mailbox: match[:mailbox], uidvalidity: match[:uidvalidity], uid: match[:uid],
      roles: [match[:role]].compact, provider_id: match[:provider_id]
    )

    Array(match[:locations]).drop(1).reduce(identity) do |acc, location|
      acc.with_location(mailbox: location[:mailbox], uidvalidity: location[:uidvalidity],
                        uid: location[:uid], roles: [location[:role]].compact)
    end
  end

  # Idempotence: the server coordinates are what matter, not the bookkeeping fields.
  def unchanged?(stored, candidate)
    return false if stored.nil?

    stored.locations.map { |location| location.slice('mailbox', 'uidvalidity', 'uid') } ==
      candidate.locations.map { |location| location.slice('mailbox', 'uidvalidity', 'uid') }
  end
end
