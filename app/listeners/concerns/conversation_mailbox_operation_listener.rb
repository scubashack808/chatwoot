module ConversationMailboxOperationListener
  def conversation_mailbox_operation_updated(event)
    account = Account.find_by(id: event.data[:account_id])
    inbox = account&.inboxes&.find_by(id: event.data[:inbox_id])
    return if account.nil? || inbox.nil?

    tokens = user_tokens(account, inbox.members)
    # Preserve omitted keys: state-only invalidation has neither operation nor mailbox_state.
    payload = event.data.slice(:conversation_id, :operation, :state_only, :mailbox_state)

    broadcast(account, tokens, Events::Types::CONVERSATION_MAILBOX_OPERATION_UPDATED, payload)
  end
end
