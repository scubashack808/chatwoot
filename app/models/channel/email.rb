# == Schema Information
#
# Table name: channel_email
#
#  id                        :bigint           not null, primary key
#  aliases                   :string           default([]), is an Array
#  email                     :string           not null
#  forward_to_email          :string           not null
#  imap_address              :string           default("")
#  imap_authentication       :string           default("plain")
#  imap_enable_ssl           :boolean          default(TRUE)
#  imap_enabled              :boolean          default(FALSE)
#  imap_login                :string           default("")
#  imap_password             :string           default("")
#  imap_port                 :integer          default(0)
#  mailbox_sync_config       :jsonb            not null
#  provider                  :string
#  provider_config           :jsonb
#  smtp_address              :string           default("")
#  smtp_authentication       :string           default("login")
#  smtp_domain               :string           default("")
#  smtp_enable_ssl_tls       :boolean          default(FALSE)
#  smtp_enable_starttls_auto :boolean          default(TRUE)
#  smtp_enabled              :boolean          default(FALSE)
#  smtp_login                :string           default("")
#  smtp_openssl_verify_mode  :string           default("none")
#  smtp_password             :string           default("")
#  smtp_port                 :integer          default(0)
#  verified_for_sending      :boolean          default(FALSE), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :integer          not null
#
# Indexes
#
#  index_channel_email_on_aliases           (aliases) USING gin
#  index_channel_email_on_email             (email) UNIQUE
#  index_channel_email_on_forward_to_email  (forward_to_email) UNIQUE
#

class Channel::Email < ApplicationRecord
  include Channelable
  include Reauthorizable
  include ::EmailHelper

  AUTHORIZATION_ERROR_THRESHOLD = 10

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  if Chatwoot.encryption_configured?
    encrypts :imap_password
    encrypts :smtp_password
  end

  self.table_name = 'channel_email'
  # mailbox_sync_config is permitted as a nested object; Imap::MailboxSyncConfig is the contract
  # that rejects unknown keys, so permitting the object here does not permit arbitrary state.
  EDITABLE_ATTRS = [:email, :imap_enabled, :imap_login, :imap_password, :imap_address, :imap_port, :imap_enable_ssl, :imap_authentication,
                    :smtp_enabled, :smtp_login, :smtp_password, :smtp_address, :smtp_port, :smtp_domain, :smtp_enable_starttls_auto,
                    :smtp_enable_ssl_tls, :smtp_openssl_verify_mode, :smtp_authentication, :provider, :verified_for_sending,
                    { mailbox_sync_config: {}, aliases: [] }].freeze

  validates :email, uniqueness: true
  validates :forward_to_email, uniqueness: true
  validate :validate_mailbox_sync_config
  validate :validate_folder_overrides_against_server, if: :folder_overrides_changed?
  validate :aliases_exclude_the_primary_address
  validate :aliases_are_unique_across_channels
  validate :primary_address_is_not_another_channels_alias

  before_validation :normalize_aliases
  before_validation :ensure_forward_to_email, on: :create

  def name
    'Email'
  end

  # The typed view of the mailbox_sync_config column. Always safe to call: an unparseable stored
  # value falls back to the default off configuration rather than raising into a request.
  def mailbox_sync
    Imap::MailboxSyncConfig.parse(mailbox_sync_config)
  rescue Imap::MailboxSyncConfig::InvalidConfigError
    Imap::MailboxSyncConfig.default
  end

  def microsoft?
    provider == 'microsoft'
  end

  def google?
    provider == 'google'
  end

  def legacy_google?
    imap_enabled && imap_address == 'imap.gmail.com'
  end

  # Every address this inbox accepts mail at and may send from: the primary plus its aliases.
  def all_addresses
    ([email] + aliases.to_a).compact_blank.uniq
  end

  # The configured address matching the candidate, or nil. Matching uses the same
  # case-insensitive, plus-addressing rules the inbound finder already uses, and it returns the
  # CONFIGURED spelling rather than the candidate, so the address we send from is always one an
  # administrator typed rather than one a header happened to contain.
  def owned_address(candidate)
    canonical_address(candidate, all_addresses)
  end

  # Wider than owned_address on purpose: forward_to_email is not a sending identity, but mail
  # addressed to it lands back in this inbox, so it must never appear on an outgoing recipient
  # list either.
  def routes_to_self?(candidate)
    canonical_address(candidate, all_addresses + [forward_to_email]).present?
  end

  # The address a reply is sent from, in precedence order:
  #   1. the agent's per-message choice
  #   2. the address the LATEST inbound message on this conversation arrived at
  #   3. the channel primary
  # A candidate this channel does not own is dropped rather than trusted, so no stored, stale or
  # tampered value can put an address we do not own on the wire.
  def outbound_address_for(conversation, message: nil)
    owned_address(message&.content_attributes&.dig('from_email')) ||
      Email::InboundRecipientFinder.new(channel: self, conversation: conversation).perform ||
      email
  end

  private

  def canonical_address(candidate, addresses)
    normalized = normalized_address(candidate)
    return if normalized.blank?

    addresses.compact_blank.find { |address| normalized_address(address) == normalized }
  end

  def normalized_address(value)
    return if value.blank?
    return unless value.to_s.include?('@')

    normalize_email_with_plus_addressing(value.to_s.strip)
  end

  def normalize_aliases
    self.aliases = Array(aliases).map { |value| value.to_s.downcase.strip }.compact_blank.uniq
  end

  def aliases_exclude_the_primary_address
    return if aliases.blank? || email.blank?

    errors.add(:aliases, 'cannot include the primary email address') if aliases.include?(email.to_s.downcase.strip)
  end

  def aliases_are_unique_across_channels
    return if aliases.blank?

    scope = self.class.where('aliases && ARRAY[:values]::varchar[] OR LOWER(email) = ANY (ARRAY[:values]::varchar[])', values: aliases)
    scope = scope.where.not(id: id) if persisted?

    errors.add(:aliases, 'are already in use on another email inbox') if scope.exists?
  end

  def primary_address_is_not_another_channels_alias
    return if email.blank?

    scope = self.class.where('aliases @> ARRAY[?]::varchar[]', [email.to_s.downcase.strip])
    scope = scope.where.not(id: id) if persisted?

    errors.add(:email, 'is already configured as an alias on another email inbox') if scope.exists?
  end

  def ensure_forward_to_email
    self.forward_to_email ||= "#{SecureRandom.hex}@#{account.inbound_email_domain}"
  end

  def validate_mailbox_sync_config
    Imap::MailboxSyncConfig.parse(mailbox_sync_config)
  rescue Imap::MailboxSyncConfig::InvalidConfigError => e
    errors.add(:mailbox_sync_config, e.message)
  end

  # Only when the overrides themselves change, so an ordinary inbox update never reaches the mail
  # server. A mode change on its own does not re-verify folders.
  def folder_overrides_changed?
    return false unless imap_enabled?
    return false unless mailbox_sync_config_changed?

    overrides = safe_folder_overrides(mailbox_sync_config)

    overrides.present? && overrides != safe_folder_overrides(mailbox_sync_config_was)
  end

  def safe_folder_overrides(raw)
    Imap::MailboxSyncConfig.parse(raw).folder_overrides
  rescue Imap::MailboxSyncConfig::InvalidConfigError
    {}
  end

  # An override names an exact server folder, so it is checked against a fresh LIST before it is
  # stored. A folder that has since been renamed or removed is refused now rather than being found
  # broken later, at the moment it would have moved mail.
  def validate_folder_overrides_against_server
    result = Imap::FolderDiscoveryService.new(channel: self).perform
    missing = safe_folder_overrides(mailbox_sync_config).reject { |_role, name| result.selectable_folder?(name) }
    return if missing.empty?

    errors.add(:mailbox_sync_config, "these folders are not selectable on the mail server: #{missing.values.sort.join(', ')}")
  rescue Imap::Lease::LeaseNotAcquiredError
    errors.add(:mailbox_sync_config, 'mailbox is busy, try again shortly')
  rescue StandardError => e
    Rails.logger.error "[IMAP] Folder override verification failed for channel #{id} : #{e.class}"
    errors.add(:mailbox_sync_config, 'could not verify these folders against the mail server')
  end
end
