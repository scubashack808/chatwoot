# Answers one question for a conversation: which of this channel's own addresses did the
# customer most recently write to?
#
# The identity is MESSAGE-scoped by construction. It is read from the latest incoming message's
# own stored envelope rather than from a value written once onto the conversation. A field
# written at conversation creation goes stale the moment later mail arrives at a different
# address of ours, which is what the deployed fork did and what the execution plan's red-team
# finding 2 names.
#
# Nothing new is persisted for this: upstream already stores the full inbound envelope on every
# incoming email message as content_attributes['email'], so historical conversations resolve
# correctly with no backfill.
class Email::InboundRecipientFinder
  RECIPIENT_FIELDS = %w[to cc bcc].freeze
  # Message#content_attributes is an ActiveRecord `store` over a `json` column, so its contents
  # are a JSON-encoded string in the database and cannot be filtered on the SQL side. The
  # envelope check therefore happens in Ruby, over a bounded window of the newest incoming
  # messages rather than the whole conversation. In an email inbox every incoming message carries
  # an envelope, so the first row is normally the answer; the window only bounds a conversation
  # that mixes in incoming messages from another source.
  SCAN_LIMIT = 10

  pattr_initialize [:channel!, :conversation!]

  def perform
    envelope = latest_inbound_envelope
    return if envelope.blank?

    candidate_addresses(envelope).each do |candidate|
      owned = channel.owned_address(candidate)
      return owned if owned.present?
    end

    nil
  end

  private

  def latest_inbound_envelope
    return if conversation.blank?

    # reorder, not order: Message carries a default_scope of created_at ascending, which would
    # otherwise win and hand back the OLDEST inbound message, which is exactly the staleness this
    # class exists to remove. Newest-first matches how the rest of the app reads message recency.
    conversation.messages
                .incoming
                .reorder(created_at: :desc, id: :desc)
                .limit(SCAN_LIMIT)
                .select(:id, :created_at, :content_attributes)
                .filter_map { |message| envelope_of(message) }
                .first
  end

  def envelope_of(message)
    envelope = message.content_attributes.presence&.dig('email')
    envelope if envelope.is_a?(Hash)
  end

  # To, Cc and Bcc first, because a forwarder that rewrites the envelope still leaves the address
  # the customer actually typed in the headers. X-Original-To is the fallback for the case where
  # it does not.
  def candidate_addresses(envelope)
    RECIPIENT_FIELDS.flat_map { |field| Array.wrap(envelope[field]) } + [original_to(envelope)]
  end

  def original_to(envelope)
    headers = envelope['headers']
    headers.is_a?(Hash) ? headers['x-original-to'] : nil
  end
end
