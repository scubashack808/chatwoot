module ConversationMailboxOperationListener
  def conversation_mailbox_operation_updated(event)
    account = Account.find_by(id: event.data[:account_id])
    inbox = account&.inboxes&.find_by(id: event.data[:inbox_id])
    return if account.nil? || inbox.nil?

    tokens = user_tokens(account, inbox.members)
    broadcast(
      account,
      tokens,
      Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED,
      {
        conversation_id: event.data[:conversation_id],
        operation: event.data[:operation],
        mailbox_state: event.data[:mailbox_state]
      }
    )
  end
end
