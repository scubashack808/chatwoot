# Bulk-loads the source data needed to render mailbox state and the latest operation without
# issuing per-conversation queries.
class Imap::ConversationMailboxData
  def initialize(conversations:, user: nil, account_user: nil)
    @conversations = conversations
    @user = user
    @account_user = account_user
  end

  def to_h
    return {} if readable_conversations.empty?

    messages = incoming_messages.group_by(&:conversation_id)
    operations = latest_operations.index_by(&:conversation_id)

    readable_conversations.to_h do |conversation|
      operation = operations[conversation.id]
      state = Imap::ConversationMailboxState.new(
        conversation: conversation,
        incoming_messages: messages.fetch(conversation.id, []),
        latest_operation: operation
      )

      [
        conversation.id,
        {
          mailbox_state: state.to_h,
          mailbox_operation: operation&.summary
        }
      ]
    end
  end

  private

  attr_reader :conversations, :user, :account_user

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
