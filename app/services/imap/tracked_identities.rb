# Imap::TrackedIdentities is everything Chatwoot currently believes about where an inbox's mail
# lives on the server, read once and classified three ways.
#
# It exists because reconciliation asks that question twice per cycle for different reasons, and
# because the classification is load bearing rather than incidental:
#
#   probe_locations - coordinates worth asking the server about, grouped by mailbox.
#   missing_source_ids - already concluded gone. Deliberately excluded from probe_locations: their
#     stored UID is absent by definition, so probing them would report a vanished UID on every
#     future cycle and escalate to a full scan forever after the first deletion. They still need
#     their re-import tombstone refreshed, because that TTL is far shorter than the absence.
#   stale_ids - one confirmed absence so far. They stay in the probe, because a second confirmed
#     absence is what promotes them to missing, and finding them present again has to reset that
#     streak.
class Imap::TrackedIdentities
  pattr_initialize [:inbox!]

  def probe_locations
    classified[:locations]
  end

  def missing_source_ids
    classified[:missing]
  end

  def stale_ids
    classified[:stale]
  end

  private

  # One pluck and one pass. On a settled cycle this is the only database read the whole
  # reconciliation pass performs, so it deliberately avoids instantiating models.
  def classified
    @classified ||= candidates.pluck(:id, :source_id, :external_source_ids)
                              .each_with_object(empty_accumulator) { |row, acc| classify_row(row, acc) }
  end

  def empty_accumulator
    { locations: Hash.new { |hash, key| hash[key] = {} }, missing: [], stale: [] }
  end

  def classify_row(row, acc)
    id, source_id, raw = row
    identity = Imap::MessageIdentity.parse(raw&.dig(Imap::MessageIdentity::NAMESPACE))
    return if identity.nil?
    return acc[:missing] << source_id if identity.sync_state == Imap::MessageIdentity::SYNC_STATE_MISSING

    acc[:stale] << id if identity.sync_state == Imap::MessageIdentity::SYNC_STATE_STALE
    identity.locations.each { |loc| acc[:locations][loc['mailbox']][loc['uid']] = loc['uidvalidity'] }
  end

  # Only messages that already carry an identity can be reconciled. Attaching identity to
  # historical mail is Imap::IdentityBackfillService's job, and the derived state already reports
  # those separately as untracked.
  def candidates
    inbox.messages.where(message_type: :incoming).where.not(source_id: [nil, ''])
  end
end
