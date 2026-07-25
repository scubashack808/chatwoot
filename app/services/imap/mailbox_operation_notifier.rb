# Publishes the one agent-only mailbox operation event using only safe scalar/hash data.
class Imap::MailboxOperationNotifier
  def self.call(operation)
    Rails.configuration.dispatcher.dispatch(
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      Time.zone.now,
      {
        account_id: operation.account_id,
        inbox_id: operation.inbox_id,
        conversation_id: operation.conversation.display_id,
        operation: operation.summary,
        mailbox_state: Imap::ConversationMailboxState.new(conversation: operation.conversation).to_h
      }
    )
  rescue StandardError => e
    Rails.logger.warn "[IMAP::MAILBOX_OPERATION] Event dispatch failed for operation #{operation.id}: #{e.class}."
  end
end
