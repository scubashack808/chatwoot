# Bulk-loads the source data needed to render mailbox state and the latest operation without
# issuing per-conversation queries.
class Imap::ConversationMailboxData
  def initialize(conversations:, user: nil, account_user: nil)
    @conversations = conversations
    @user = user
    @account_user = account_user
  end

  # A conversation appears here only when a mailbox action on it would actually reach the mail
  # server. Anything omitted carries no mailbox_state at all, so the payload looks exactly like
  # stock Chatwoot and the dashboard offers no mailbox actions for it.
  #
  # This is the same gate Imap::MailboxOperationRequest enforces, applied one step earlier. Without
  # it the two disagree: enforcement is per inbox and per message, while publication was per
  # account, so every inbox that had not had its turn showed Archive, Spam and Trash that could
  # only refuse.
  def to_h
    return {} if readable_conversations.empty?
    # Nothing on this page can mutate a provider, so the message and operation reads would be
    # thrown away. This is the ordinary case for an account whose inboxes have not been activated,
    # and it keeps the gate from costing anything at all there.
    return {} if mutable_inbox_ids.empty?

    messages = incoming_messages.group_by(&:conversation_id)
    operations = latest_operations.index_by(&:conversation_id)

    readable_conversations.each_with_object({}) do |conversation, payload|
      data = conversation_payload(conversation, messages, operations)
      payload[conversation.id] = data if data
    end
  end

  private

  attr_reader :conversations, :user, :account_user

  def conversation_payload(conversation, messages, operations)
    return unless mutable_inbox_ids.include?(conversation.inbox_id)

    operation = operations[conversation.id]
    state = Imap::ConversationMailboxState.new(
      conversation: conversation,
      incoming_messages: messages.fetch(conversation.id, []),
      latest_operation: operation
    )
    return unless state.actionable?

    { mailbox_state: state.to_h, mailbox_operation: operation&.summary }
  end

  def conversation_records
    @conversation_records ||= conversations.to_a
  end

  def readable_conversations
    @readable_conversations ||= if user.nil? || account_user&.administrator?
                                  conversation_records
                                elsif user.is_a?(User)
                                  inbox_ids = user.inboxes.where(id: conversation_records.pluck(:inbox_id)).pluck(:id)
                                  conversation_records.select { |conversation| inbox_ids.include?(conversation.inbox_id) }
                                else
                                  []
                                end
  end

  # One query for the whole page rather than one per conversation. An inbox below mode active
  # cannot mutate the provider, so publishing mailbox state for it would publish buttons that are
  # guaranteed to refuse with mailbox_sync_not_active.
  #
  # Deliberately config-only, with no IMAP connection. Whether this inbox's archive, trash and spam
  # resolve to real server mailboxes is a question only the mail server can answer, and asking it
  # while rendering a conversation list is not affordable. Imap::MailboxTargets answers it for an
  # operator before an inbox is activated. Enforcing it as a condition of entering mode active is a
  # separate change: it would make activation contact the mail server, which is a decision about
  # Channel::Email rather than about what this publishes.
  def mutable_inbox_ids
    @mutable_inbox_ids ||= Inbox.where(id: readable_conversations.map(&:inbox_id).uniq)
                                .includes(:channel)
                                .select { |inbox| provider_mutation_allowed?(inbox) }
                                .to_set(&:id)
  end

  def provider_mutation_allowed?(inbox)
    channel = inbox.channel
    channel.respond_to?(:mailbox_sync) && channel.mailbox_sync.provider_mutation_allowed?
  end

  def incoming_messages
    Message.unscoped
           .where(conversation_id: readable_conversations.pluck(:id), message_type: Message.message_types[:incoming])
           .select(:id, :conversation_id, :external_source_ids)
           .order(:conversation_id, :id)
  end

  def latest_operations
    EmailMailboxOperation
      .where(conversation_id: readable_conversations.pluck(:id))
      .select('DISTINCT ON (conversation_id) email_mailbox_operations.*')
      .order(:conversation_id, created_at: :desc, id: :desc)
  end
end
