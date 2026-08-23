# Decides whether a message found in the server's Sent folder unambiguously belongs to an existing
# Chatwoot conversation.
#
# The execution plan is explicit that the first Sent patch "threads only messages that
# unambiguously reference an existing Chatwoot conversation" and that it "does not fabricate a new
# contact/conversation for an unthreaded message sent in another client". This class is where that
# refusal lives, so the rule is one readable decision rather than a fallback chain.
#
# It is deliberately stricter than Imap::ImapMailbox's inbound threading, which is allowed to fall
# through to creating a conversation. Here, no match and an ambiguous match have the same outcome:
# nothing is created.
class Imap::SentThreadResolver
  # Chatwoot's own outgoing mail carries this address in References, so a reply written in another
  # client and quoting our thread still points back at the exact conversation.
  CONVERSATION_UUID_PATTERN = %r{account/(\d+)/conversation/([a-zA-Z0-9-]+)@}

  Resolution = Struct.new(:conversation, :reason, keyword_init: true)

  UNTHREADED = 'unthreaded'.freeze
  AMBIGUOUS = 'ambiguous'.freeze

  pattr_initialize [:inbox!, :mail!]

  def perform
    candidates = [
      ['in_reply_to', conversations_for(in_reply_to_ids)],
      ['references', conversations_for(reference_ids)],
      ['conversation_uuid', conversations_by_uuid]
    ]

    distinct = candidates.flat_map(&:last).uniq
    return Resolution.new(conversation: nil, reason: UNTHREADED) if distinct.empty?
    return Resolution.new(conversation: nil, reason: AMBIGUOUS) if distinct.many?

    reason = candidates.find { |_source, found| found.any? }.first
    Resolution.new(conversation: inbox.conversations.find_by(id: distinct.first), reason: reason)
  end

  private

  def in_reply_to_ids
    normalize(mail.in_reply_to)
  end

  def reference_ids
    normalize(mail.references)
  end

  def normalize(value)
    Array.wrap(value).filter_map { |id| id.to_s.delete('<>').strip.presence }
  end

  # Only messages already in THIS inbox count. A Message-ID that belongs to another inbox is not
  # evidence about this conversation.
  def conversations_for(message_ids)
    return [] if message_ids.empty?

    inbox.messages.where(source_id: message_ids).reorder(nil).distinct.pluck(:conversation_id)
  end

  def conversations_by_uuid
    uuids = (in_reply_to_ids + reference_ids).filter_map do |id|
      match = CONVERSATION_UUID_PATTERN.match(id)
      match[2] if match.present? && match[1].to_i == inbox.account_id
    end
    return [] if uuids.empty?

    inbox.conversations.where(uuid: uuids).reorder(nil).pluck(:id)
  end
end
