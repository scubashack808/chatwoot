# Imap::MailboxReconciliationService closes the reverse loop. Every other mailbox path in this
# stack is forward: Chatwoot acts and the provider follows. This one reads where the server
# actually holds each tracked message and brings the stored identity back in line, so a move or a
# delete performed in Apple Mail, on a phone, or by the provider itself stops being invisible.
#
# Three properties are load bearing.
#
# 1. It never mutates the provider. Every mailbox is opened with EXAMINE and only Message-ID
#    headers are read, so this is safe in `observe` mode, where provider mutation is forbidden.
#
# 2. Absence is only ever concluded from a window it actually read end to end, and only after two
#    consecutive such windows. A truncated batch, a transient IMAP failure and a real deletion are
#    indistinguishable from a single index, and Imap::BaseFetchEmailService::MAX_MESSAGES_PER_SYNC
#    means "not in this sync" has never meant "not on the server". The first confirmed absence
#    only marks the identity stale, which changes no derived state; the second promotes it to the
#    existing `missing` vocabulary.
#
# 3. It never recreates mail and never destroys it. It does not delete the Chatwoot message or
#    conversation, and when it concludes a message is gone it writes the upstream re-import
#    tombstone (Imap::DeletedMessageTracker) so the ingestion path refuses to bring it back. The
#    tombstone is rewritten on every later cycle the message is still absent, because its TTL is
#    two days and the message may be gone for longer than that.
#
# Every selectable folder is scanned, not just the four role folders. A message an operator filed
# into a custom folder has moved, not vanished, and calling that a deletion would both lie in the
# derived state and tombstone live mail.
class Imap::MailboxReconciliationService
  # One mailbox above this many messages is reported as an untrustworthy window rather than
  # scanned. Reconciliation then still applies every move it can see but refuses to conclude that
  # anything is absent.
  MAX_MESSAGES_PER_MAILBOX = 20_000
  CANDIDATE_BATCH_SIZE = 500

  # Fixed precedence for ordering the locations of a message the server holds in more than one
  # place. It exists so that a duplicate resolves to the same identity on every cycle instead of
  # flapping with whatever order the server happened to be scanned in.
  ROLE_ORDER = %w[inbox archive spam trash].freeze

  pattr_initialize [:channel!]

  # The probe, the scan and the writes all happen inside one lease on purpose. If the lease were
  # released between them, a mailbox operation could move a message and rewrite its identity while
  # this pass still held a pre-move view, and the pass would then silently revert the user's move
  # in Chatwoot's own records. The lease is what serializes all per-inbox mailbox work.
  #
  # How long a cycle may rely on the probe alone before enumerating again. The probe detects a
  # tracked message LEAVING a location it was recorded in. It cannot see a copy APPEARING somewhere
  # new, because nothing it asks about covers a mailbox Chatwoot has no identity in: a Gmail label
  # added to an existing message, or a plain IMAP COPY, leaves the original exactly where it was.
  # Only enumeration finds those, so enumeration still happens on this interval regardless.
  FULL_SCAN_INTERVAL = 15.minutes

  # An ordinary cycle stops at the probe. Full enumeration is what makes a conclusion of absence
  # honest and is the only thing that sees a new copy appear, but neither is needed on a cycle where
  # every tracked message is still exactly where Chatwoot left it.
  #
  # The result is that a move or a delete is reflected within a cycle, while a copy or a label is
  # reflected within FULL_SCAN_INTERVAL, which is no slower than enumerating on every cycle was.
  def perform
    reason = blocking_reason
    return Imap::ReconciliationReport.skipped(inbox_id: channel.inbox.id, reason: reason) if reason

    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      next scan_and_reconcile(client, session, nil) if full_scan_due?

      probe = probe_server(client, session)
      probe.settled? ? settled(probe) : scan_and_reconcile(client, session, probe)
    end
  end

  private

  def scan_and_reconcile(client, session, probe)
    report = reconcile(read_server(client, session), probe)
    full_scan_clock.record
    report
  end

  # An inbox that has never been enumerated has no trustworthy picture to probe against, so the
  # first cycle always enumerates.
  def full_scan_due?
    full_scan_clock.due?(FULL_SCAN_INTERVAL)
  end

  def full_scan_clock
    @full_scan_clock ||= Imap::CycleClock.new(inbox: channel.inbox, key_template: Redis::RedisKeys::IMAP_FULL_SCAN_AT)
  end

  def probe_server(client, session)
    Imap::MailboxProbe.new(client: client, session: session, locations: tracked.probe_locations).perform
  end

  def tracked
    @tracked ||= Imap::TrackedIdentities.new(inbox: channel.inbox)
  end

  # Nothing moved, so no identity changes and no scan happens. The one thing a settled cycle still
  # owes is refreshing the tombstones of messages already concluded missing: that TTL is two days
  # and a message deleted on the provider stays deleted for very much longer than that.
  def settled(probe)
    tombstones = tracked.missing_source_ids
    deleted_message_tracker.record(tombstones) if tombstones.any?

    Imap::ReconciliationReport.settled(inbox_id: channel.inbox.id, probe: probe,
                                       tombstoned: tombstones.length, recovered: promote_recovered)
  end

  # A settled probe found every tracked identity exactly where it was recorded, which includes any
  # that a previous cycle had written off as stale. That is a recovery and it has to reset the
  # streak, or one transient IMAP failure would leave a live message one cycle away from being
  # marked missing for as long as the probe keeps settling.
  def promote_recovered
    ids = tracked.stale_ids
    return 0 if ids.blank?

    Message.where(id: ids).find_each do |message|
      identity = message.imap_identity
      next if identity.nil?

      message.write_imap_identity!(identity.with_sync_state(Imap::MessageIdentity::SYNC_STATE_VERIFIED))
    end

    ids.length
  end

  # Reconciliation is dark twice over: the account feature flag and the per-inbox mode. `observe`
  # is enough, because nothing here mutates the provider.
  def blocking_reason
    return 'imap_disabled' unless channel.is_a?(Channel::Email) && channel.imap_enabled?
    return 'feature_disabled' unless channel.account.feature_enabled?('email_mailbox_actions')
    return 'mailbox_sync_off' if channel.mailbox_sync.off?

    nil
  end

  def read_server(client, session)
    Imap::MailboxScan.new(
      client: client, session: session,
      mailboxes: mailboxes_to_scan(session), max_messages: MAX_MESSAGES_PER_MAILBOX
    ).perform
  end

  # Every selectable folder the server lists, tagged with a mailbox role where the inbox has one
  # resolved. INBOX is guaranteed present: a LIST that somehow omitted it would otherwise make
  # every inbox message look absent.
  def mailboxes_to_scan(session)
    listing = session.command { |imap| imap.list('', '*') }
    roles = role_by_mailbox(Imap::FolderDiscoveryService.result_for(folders: listing, config: channel.mailbox_sync))

    selectable = Imap::FolderDiscoveryService.normalize(listing)
                                             .reject { |folder| folder[:attributes].include?(Imap::FolderDiscoveryService::NOSELECT) }
                                             .pluck(:name)

    ([Imap::MailboxSyncConfig::RESTORE_TARGET] | selectable).map { |name| [name, roles[name]] }
  end

  def role_by_mailbox(result)
    resolved = Imap::FolderDiscoveryService::ROLE_ATTRIBUTES.keys.filter_map do |role|
      folder = result.for_role(role)
      [folder.selected, role] if folder&.available?
    end

    resolved.to_h.merge(Imap::MailboxSyncConfig::RESTORE_TARGET => 'inbox')
  end

  def reconcile(scan, probe)
    report = Imap::ReconciliationReport.for_scan(inbox_id: channel.inbox.id, scan: scan, probe: probe)
    tombstones = []

    candidates.find_each(batch_size: CANDIDATE_BATCH_SIZE) do |message|
      report[:candidates] += 1
      reconcile_message(message, scan, report, tombstones)
    end

    deleted_message_tracker.record(tombstones)
    report[:tombstoned] = tombstones.length
    report
  end

  # Only messages that already carry an identity can be reconciled. Attaching identity to
  # historical mail is Imap::IdentityBackfillService's job, and the derived state already reports
  # those separately as untracked.
  def candidates
    channel.inbox.messages.where(message_type: :incoming).where.not(source_id: [nil, ''])
  end

  def reconcile_message(message, scan, report, tombstones)
    identity = message.imap_identity
    return report[:untracked] += 1 if identity.nil?

    hits = scan.hits_for(message.source_id)
    return record_presence(message, identity, hits, report) if hits.present?

    record_absence(message, identity, scan, report, tombstones)
  end

  def record_presence(message, identity, hits, report)
    locations = ordered_locations(hits)
    return record_unchanged_locations(message, identity, report) if identity.locations == locations

    message.write_imap_identity!(identity.with_locations(locations, provider_id: shared_provider_id(hits)))
    report[change_kind(identity, locations)] += 1
  end

  # The server agrees with what is stored, so the coordinates are left completely alone. Only a
  # message previously written off as stale or missing is touched, to record that it is back.
  def record_unchanged_locations(message, identity, report)
    return report[:unchanged] += 1 if identity.sync_state == Imap::MessageIdentity::SYNC_STATE_VERIFIED

    message.write_imap_identity!(identity.with_sync_state(Imap::MessageIdentity::SYNC_STATE_VERIFIED))
    report[:recovered] += 1
  end

  def record_absence(message, identity, scan, report, tombstones)
    return report[:inconclusive] += 1 unless scan.conclusive?

    case identity.sync_state
    when Imap::MessageIdentity::SYNC_STATE_MISSING
      tombstones << message.source_id
      report[:still_missing] += 1
    when Imap::MessageIdentity::SYNC_STATE_STALE
      message.write_imap_identity!(identity.with_sync_state(Imap::MessageIdentity::SYNC_STATE_MISSING))
      tombstones << message.source_id
      report[:marked_missing] += 1
    else
      message.write_imap_identity!(identity.with_sync_state(Imap::MessageIdentity::SYNC_STATE_STALE))
      report[:absent_once] += 1
    end
  end

  def ordered_locations(hits)
    hits.map { |hit| location_for(hit) }
        .uniq { |location| [location['mailbox'], location['uid']] }
        .sort_by { |location| [ROLE_ORDER.index(location['roles'].first) || ROLE_ORDER.length, location['mailbox'], location['uid']] }
  end

  def location_for(hit)
    Imap::MessageIdentity.location_for(
      mailbox: hit[:mailbox], uidvalidity: hit[:uidvalidity], uid: hit[:uid], roles: [hit[:role]].compact
    )
  end

  # Gmail exposes one message through several mailboxes at once, and those hits share a
  # provider-stable id. Anything else is genuinely more than one copy.
  def shared_provider_id(hits)
    provider_ids = hits.filter_map { |hit| hit[:provider_id] }.uniq
    provider_ids.one? ? provider_ids.first : nil
  end

  def change_kind(identity, locations)
    return :moved if mailboxes_of(identity.locations) != mailboxes_of(locations)
    return :uidvalidity_resolved if generations_of(identity.locations) != generations_of(locations)

    :moved
  end

  def mailboxes_of(locations)
    locations.pluck('mailbox').sort
  end

  def generations_of(locations)
    locations.pluck('uidvalidity').sort
  end

  def deleted_message_tracker
    @deleted_message_tracker ||= Imap::DeletedMessageTracker.new(inbox: channel.inbox)
  end
end
