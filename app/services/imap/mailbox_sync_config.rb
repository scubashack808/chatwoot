# Imap::MailboxSyncConfig is the typed application contract over the channel_email
# mailbox_sync_config JSONB column.
#
# The column is deliberately separate from provider_config, which OAuth refresh replaces
# wholesale. It holds only administrator intent: how much this inbox is allowed to do, the exact
# server folder chosen for each role, and how Sent is handled. It never holds a credential, a
# token, or a discovery result cached as authority. Discovery is re-read and re-validated when an
# override is saved and again when it is used.
class Imap::MailboxSyncConfig
  class InvalidConfigError < StandardError; end

  # off      : nothing runs for this inbox.
  # observe  : discovery, identity capture, backfill, and reconciliation, but no provider mutation.
  # active   : a human action may mutate the provider, and only when the account flag is also on.
  MODES = %w[off observe active].freeze

  SENT_MODES = %w[provider_managed append disabled].freeze
  ROLES = %w[archive trash spam sent].freeze
  PERMITTED_KEYS = %w[mode sent_mode folder_overrides].freeze

  DEFAULT_MODE = 'off'.freeze
  DEFAULT_SENT_MODE = 'provider_managed'.freeze

  # INBOX is the canonical restore target. It is never guessed from special-use attributes and
  # never taken from an administrator override.
  RESTORE_TARGET = 'INBOX'.freeze

  attr_reader :mode, :sent_mode, :folder_overrides

  def initialize(mode:, sent_mode:, folder_overrides:)
    @mode = mode
    @sent_mode = sent_mode
    @folder_overrides = folder_overrides.freeze
    freeze
  end

  class << self
    def default
      new(mode: DEFAULT_MODE, sent_mode: DEFAULT_SENT_MODE, folder_overrides: {})
    end

    def parse(raw)
      return default if raw.nil?

      attributes = normalize_root(raw)
      reject_unknown_keys(attributes)

      new(
        mode: parse_enum(attributes, 'mode', MODES, DEFAULT_MODE),
        sent_mode: parse_enum(attributes, 'sent_mode', SENT_MODES, DEFAULT_SENT_MODE),
        folder_overrides: parse_folder_overrides(attributes['folder_overrides'])
      )
    end

    private

    def normalize_root(raw)
      raise InvalidConfigError, 'mailbox_sync_config must be an object' unless raw.respond_to?(:to_h)

      raw.to_h.transform_keys(&:to_s)
    rescue TypeError, NoMethodError
      raise InvalidConfigError, 'mailbox_sync_config must be an object'
    end

    def reject_unknown_keys(attributes)
      unknown = attributes.keys - PERMITTED_KEYS
      return if unknown.empty?

      raise InvalidConfigError, "mailbox_sync_config has unknown keys: #{unknown.sort.join(', ')}"
    end

    def parse_enum(attributes, key, allowed, fallback)
      return fallback unless attributes.key?(key)

      value = attributes[key].to_s
      return value if allowed.include?(value)

      raise InvalidConfigError, "mailbox_sync_config #{key} must be one of #{allowed.join(', ')}"
    end

    def parse_folder_overrides(raw)
      return {} if raw.nil?
      raise InvalidConfigError, 'mailbox_sync_config folder_overrides must be an object' unless raw.is_a?(Hash)

      overrides = raw.transform_keys(&:to_s)
      unknown = overrides.keys - ROLES
      raise InvalidConfigError, "mailbox_sync_config folder_overrides has unknown roles: #{unknown.sort.join(', ')}" if unknown.any?

      overrides.filter_map { |role, folder| build_override(role, folder) }.to_h
    end

    # A blank override leaves the role unconfigured. That role's action stays unavailable rather
    # than falling back to a guessed folder.
    def build_override(role, folder)
      return nil if folder.nil?
      raise InvalidConfigError, "mailbox_sync_config folder_overrides #{role} must be a string" unless folder.is_a?(String)
      return nil if folder.strip.empty?

      [role, folder]
    end
  end

  def off?
    mode == 'off'
  end

  def observe?
    mode == 'observe'
  end

  def active?
    mode == 'active'
  end

  def discovery_allowed?
    !off?
  end

  # Whether this inbox may change anything on the mail server. The account-level mutation flag is
  # a separate gate checked by the action path; this only reports the per-inbox half.
  def provider_mutation_allowed?
    active?
  end

  def override_for(role)
    folder_overrides[role.to_s]
  end

  def restore_target
    RESTORE_TARGET
  end

  def to_h
    { 'mode' => mode, 'sent_mode' => sent_mode, 'folder_overrides' => folder_overrides }
  end
end
