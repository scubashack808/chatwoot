# Publishes the one agent-only mailbox operation event using only safe scalar/hash data.
class Imap::MailboxOperationNotifier
  # The third publication path, and the easiest to forget: this pushes straight to every inbox
  # member over the realtime channel. It carries the same gate as the payload and the controller,
  # and omits the key entirely rather than sending null, because the dashboard writes whatever
  # arrives onto its conversation object and then decides with hasOwnProperty.
  def self.call(operation)
    data = {
      account_id: operation.account_id,
      inbox_id: operation.inbox_id,
      conversation_id: operation.conversation.display_id,
      operation: operation.summary
    }
    state = Imap::ConversationMailboxState.publishable(conversation: operation.conversation)
    data[:mailbox_state] = state.to_h if state

    Rails.configuration.dispatcher.dispatch(
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      Time.zone.now,
      data
    )
  rescue StandardError => e
    Rails.logger.warn "[IMAP::MAILBOX_OPERATION] Event dispatch failed for operation #{operation.id}: #{e.class}."
  end
end
