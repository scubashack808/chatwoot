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

  SYNC_STATE_VERIFIED = 'verified'.freeze
  SYNC_STATE_STALE = 'stale'.freeze

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
    others = locations.reject { |candidate| candidate['mailbox'] == replacement['mailbox'] }

    self.class.new(
      version: version + 1,
      provider_id: provider_id.presence || self.provider_id,
      sync_state: SYNC_STATE_VERIFIED,
      last_verified_at: Time.current.iso8601,
      locations: [replacement] + others
    )
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
end
