module ConversationMailboxOperationListener
  def conversation_mailbox_operation_updated(event)
    account = Account.find_by(id: event.data[:account_id])
    inbox = account&.inboxes&.find_by(id: event.data[:inbox_id])
    return if account.nil? || inbox.nil?

    tokens = user_tokens(account, inbox.members)
    payload = {
      conversation_id: event.data[:conversation_id],
      operation: event.data[:operation]
    }
    # Carried through only when the notifier published it. Passing the key unconditionally would
    # broadcast an explicit null, which the dashboard counts as mailbox data.
    payload[:mailbox_state] = event.data[:mailbox_state] if event.data.key?(:mailbox_state)

    broadcast(account, tokens, Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED, payload)
  end
end
