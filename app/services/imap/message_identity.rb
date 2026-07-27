# Imap::MessageIdentity is the value stored under messages.external_source_ids["imap"].
#
# It is the durable, server-side identity of a message: the exact mailbox it lives in, the
# UIDVALIDITY generation that UID belongs to, the UID itself, the special-use role(s) of that
# mailbox, and a provider-stable id such as Gmail's X-GM-MSGID where the server offers one.
#
# Sequence numbers are never stored. They are positional and change whenever anything is expunged,
# so persisting one would be a silent corruption waiting to happen. RFC Message-ID stays what it
# already was, a dedupe and recovery hint, never mutation authority.
#
# locations is an array because a single Gmail message can be exposed through more than one
# mailbox at once via labels. The flat mailbox/uidvalidity/uid fields always mirror the first
# location; both are written in one place here so they cannot drift apart.
class Imap::MessageIdentity
  NAMESPACE = 'imap'.freeze

  # verified : the last server read found the message where these coordinates say it is.
  # stale    : one conclusive server read did not find it. Nothing derived changes on this state;
  #            it exists so that a second consecutive confirmed absence, and only a second, can
  #            promote to missing.
  # missing  : the provider no longer holds this message.
  SYNC_STATE_VERIFIED = 'verified'.freeze
  SYNC_STATE_STALE = 'stale'.freeze
  SYNC_STATE_MISSING = 'missing'.freeze

  attr_reader :version, :provider_id, :sync_state, :last_verified_at, :locations

  def initialize(version:, provider_id:, sync_state:, last_verified_at:, locations:)
    @version = version
    @provider_id = provider_id
    @sync_state = sync_state
    @last_verified_at = last_verified_at
    @locations = locations
    freeze
  end

  class << self
    def build(mailbox:, uidvalidity:, uid:, roles: [], provider_id: nil)
      new(
        version: 1,
        provider_id: provider_id,
        sync_state: SYNC_STATE_VERIFIED,
        last_verified_at: Time.current.iso8601,
        locations: [location_for(mailbox: mailbox, uidvalidity: uidvalidity, uid: uid, roles: roles)]
      )
    end

    def parse(raw)
      return nil if raw.blank?

      attributes = raw.to_h.transform_keys(&:to_s)
      locations = Array(attributes['locations']).map { |location| location.to_h.transform_keys(&:to_s) }
      return nil if locations.empty?

      new(
        version: attributes['version'].to_i,
        provider_id: attributes['provider_id'],
        sync_state: attributes['sync_state'],
        last_verified_at: attributes['last_verified_at'],
        locations: locations
      )
    end

    def location_for(mailbox:, uidvalidity:, uid:, roles: [])
      { 'mailbox' => mailbox.to_s, 'uidvalidity' => uidvalidity.to_i, 'uid' => uid.to_i, 'roles' => Array(roles).map(&:to_s) }
    end
  end

  def primary
    locations.first
  end

  def mailbox
    primary['mailbox']
  end

  def uidvalidity
    primary['uidvalidity']
  end

  def uid
    primary['uid']
  end

  def roles
    primary['roles']
  end

  # A UIDVALIDITY change invalidates every UID in that mailbox, so a stored UID from the previous
  # generation must never be reused against the new one.
  def stale_for?(mailbox:, uidvalidity:)
    location = locations.find { |candidate| candidate['mailbox'] == mailbox.to_s }
    return false if location.nil?

    location['uidvalidity'] != uidvalidity.to_i
  end

  def location_for(mailbox)
    locations.find { |candidate| candidate['mailbox'] == mailbox.to_s }
  end

  # Adds or replaces the location for one mailbox and bumps the monotonic identity version.
  def with_location(mailbox:, uidvalidity:, uid:, roles: [], provider_id: nil)
    replacement = self.class.location_for(mailbox: mailbox, uidvalidity: uidvalidity, uid: uid, roles: roles)
    update_location(replacement, provider_id: provider_id)
  end

  # A UID MOVE replaces its source location rather than adding a Gmail-style second location.
  # It shares the same version+1 write path as with_location.
  def moved_to(mailbox:, uidvalidity:, uid:, roles: [], source_mailbox: self.mailbox)
    replacement = self.class.location_for(mailbox: mailbox, uidvalidity: uidvalidity, uid: uid, roles: roles)
    update_location(replacement, provider_id: nil, replaces: source_mailbox)
  end

  # Records what the latest server read said about whether this message is still there, without
  # touching the coordinates or the monotonic version. An observation is not a location change, so
  # an operation frozen against this identity stays valid. last_verified_at is deliberately left
  # alone: it keeps meaning "when these coordinates were last confirmed", which is exactly the
  # thing a stale or missing identity no longer has.
  def with_sync_state(state)
    return self if sync_state == state

    self.class.new(version: version, provider_id: provider_id, sync_state: state,
                   last_verified_at: last_verified_at, locations: locations)
  end

  # Replaces the whole location set from an authoritative server read. Unlike with_location this
  # does not merge: a reconciliation pass has just seen every copy the server holds, so anything
  # not in that list is no longer there.
  def with_locations(new_locations, provider_id: nil)
    self.class.new(version: version + 1, provider_id: provider_id.presence || self.provider_id,
                   sync_state: SYNC_STATE_VERIFIED, last_verified_at: Time.current.iso8601,
                   locations: new_locations)
  end

  def to_h
    {
      'version' => version,
      'mailbox' => mailbox,
      'uidvalidity' => uidvalidity,
      'uid' => uid,
      'roles' => roles,
      'provider_id' => provider_id,
      'sync_state' => sync_state,
      'last_verified_at' => last_verified_at,
      'locations' => locations
    }
  end

  private

  def update_location(replacement, provider_id:, replaces: nil)
    replaced_mailboxes = [replacement['mailbox'], replaces].compact
    others = locations.reject { |candidate| replaced_mailboxes.include?(candidate['mailbox']) }

    self.class.new(
      version: version + 1,
      provider_id: provider_id.presence || self.provider_id,
      sync_state: SYNC_STATE_VERIFIED,
      last_verified_at: Time.current.iso8601,
      locations: [replacement] + others
    )
  end
end
