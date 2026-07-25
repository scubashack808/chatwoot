# Creates or resumes one durable conversation mailbox operation after checking both dark gates.
#
# This is deliberately the only request entrypoint. It freezes the exact incoming message
# identities the worker may act on, so a retry never expands onto mail that arrived later.
class Imap::MailboxOperationRequest
  Result = Struct.new(:operation, :error_code, :http_status, keyword_init: true) do
    def accepted?
      operation.present?
    end
  end

  pattr_initialize [:conversation!, :user!, :action!, :idempotency_key!]

  def perform
    gate = mutation_gate
    return gate if gate

    action_name = action.to_s
    return refused('invalid_action') unless EmailMailboxOperation::ACTIONS.include?(action_name)
    return refused('idempotency_key_required') if idempotency_key.blank?

    existing = existing_operation
    return resume(existing, action_name) if existing

    create_operation(action_name)
  rescue ActiveRecord::RecordNotUnique
    resolve_create_race(action_name)
  end

  private

  def mutation_gate
    return refused('mailbox_actions_disabled', :forbidden) unless conversation.account.feature_enabled?('email_mailbox_actions')

    channel = conversation.inbox.channel
    return refused('email_inbox_required') unless channel.is_a?(Channel::Email) && channel.imap_enabled?
    return refused('mailbox_sync_not_active') unless channel.mailbox_sync.provider_mutation_allowed?
  end

  def existing_operation
    EmailMailboxOperation.find_by(account_id: conversation.account_id, idempotency_key: idempotency_key)
  end

  def create_operation(action_name)
    items = frozen_items(action_name)
    return refused('no_eligible_messages') if items.empty?

    operation = EmailMailboxOperation.create!(
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      user: user,
      action: action_name,
      idempotency_key: idempotency_key,
      items: items
    )

    Result.new(operation: operation, http_status: :accepted)
  end

  def resume(existing, action_name)
    return conflict('idempotency_key_reused') unless same_request?(existing, action_name)
    return conflict('stale_idempotency_key') if newer_operation_exists?(existing)

    existing.update!(status: :pending, error_code: nil) if existing.terminal? && !existing.succeeded?
    Result.new(operation: existing, http_status: :accepted)
  rescue ActiveRecord::RecordNotUnique
    conflict('operation_in_progress')
  end

  def resolve_create_race(action_name)
    existing = existing_operation
    return resume(existing, action_name) if existing

    conflict('operation_in_progress')
  end

  def same_request?(existing, action_name)
    existing.conversation_id == conversation.id && existing.action == action_name
  end

  def newer_operation_exists?(existing)
    EmailMailboxOperation.where(conversation_id: conversation.id)
                         .exists?(['created_at > ?', existing.created_at])
  end

  def frozen_items(action_name)
    conversation.messages.incoming.order(:id).filter_map do |message|
      frozen_item_for(message, action_name)
    end
  end

  def frozen_item_for(message, action_name)
    identity = message.imap_identity
    return unavailable_item(message, 'identity_missing') if identity.nil?
    return unavailable_item(message, 'provider_missing') if identity.sync_state == 'missing'

    source = source_for(identity, action_name)
    return if source.nil?

    {
      'message_id' => message.id,
      'identity_version' => identity.version,
      'source' => source,
      'provider_id' => identity.provider_id,
      'message_source_id' => message.source_id
    }
  end

  def unavailable_item(message, error_code)
    {
      'message_id' => message.id,
      'message_source_id' => message.source_id,
      'preflight_error' => error_code
    }
  end

  def source_for(identity, action_name)
    case action_name
    when 'archive'
      location_for_role(identity, 'inbox')
    when 'restore'
      %w[trash spam archive].filter_map { |role| location_for_role(identity, role) }.first
    else
      location_for_role(identity, 'inbox') || identity.primary
    end
  end

  def location_for_role(identity, role)
    identity.locations.find { |location| Array(location['roles']).include?(role) }
  end

  def refused(error_code, http_status = :unprocessable_entity)
    Result.new(error_code: error_code, http_status: http_status)
  end

  def conflict(error_code)
    refused(error_code, :conflict)
  end
end
