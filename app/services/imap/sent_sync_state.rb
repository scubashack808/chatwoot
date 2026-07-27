# Imap::SentSyncState is the visible per-message state of Sent synchronisation.
#
# It lives beside the message identity, under external_source_ids["imap"]["sent_sync"], because an
# SMTP success is delivery success and must never be re-reported as a Sent-sync outcome. The two
# facts are therefore stored separately: message.status stays what delivery said, and this records
# whether the server copy has been located, appended, or has failed and will be retried.
#
# It carries no message body, no credential, and no raw server exception: the error is a normalised
# class-plus-summary string.
class Imap::SentSyncState
  KEY = 'sent_sync'.freeze

  # The copy exists on the server and its UID identity is recorded.
  SYNCED = 'synced'.freeze
  # Provider-managed: the provider is expected to have saved the copy, and it is not there yet.
  AWAITING_PROVIDER_COPY = 'awaiting_provider_copy'.freeze
  # The attempt raised. It is retried on the next cycle, idempotently, because the search runs
  # before the append.
  FAILED = 'failed'.freeze
  # More than one copy already matches this Message-ID. Appending another would compound it, so
  # the item stops here and stays visible.
  CONFLICT = 'conflict'.freeze

  MAX_ERROR_LENGTH = 200

  attr_reader :state, :attempts, :error, :last_attempt_at

  def initialize(state:, attempts:, error:, last_attempt_at:)
    @state = state
    @attempts = attempts
    @error = error
    @last_attempt_at = last_attempt_at
    freeze
  end

  class << self
    def build(state:, attempts: 0, error: nil)
      new(
        state: state,
        attempts: attempts.to_i,
        error: normalize_error(error),
        last_attempt_at: Time.current.iso8601
      )
    end

    def parse(raw)
      return nil if raw.blank?

      attributes = raw.to_h.transform_keys(&:to_s)
      return nil if attributes['state'].blank?

      new(
        state: attributes['state'],
        attempts: attributes['attempts'].to_i,
        error: attributes['error'],
        last_attempt_at: attributes['last_attempt_at']
      )
    end

    # Server exceptions can carry mailbox contents and credentials in their text. Only the class
    # and a truncated summary are ever persisted.
    def normalize_error(error)
      return nil if error.nil?
      return error.to_s.truncate(MAX_ERROR_LENGTH) if error.is_a?(String)

      "#{error.class}: #{error.message}".truncate(MAX_ERROR_LENGTH)
    end
  end

  def synced?
    state == SYNCED
  end

  def to_h
    { 'state' => state, 'attempts' => attempts, 'error' => error, 'last_attempt_at' => last_attempt_at }
  end
end
