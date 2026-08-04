class Api::V1::Accounts::Conversations::MailboxOperationsController < Api::V1::Accounts::Conversations::BaseController
  before_action :authorize_mailbox_action, only: [:index, :show, :create]
  before_action :ensure_mailbox_actions_enabled, only: [:index, :show]

  def index
    operations = EmailMailboxOperation.where(conversation_id: @conversation.id).order(created_at: :desc, id: :desc)

    render json: with_mailbox_state(operations: operations.map(&:summary))
  end

  def show
    operation = EmailMailboxOperation.find_by!(id: params[:id], conversation_id: @conversation.id)

    render_operation(operation)
  end

  def create
    result = Imap::MailboxOperationRequest.new(
      conversation: @conversation,
      user: Current.user,
      action: permitted_params[:action],
      idempotency_key: permitted_params[:idempotency_key]
    ).perform

    return render_error(result) unless result.accepted?

    Imap::MailboxOperationNotifier.call(result.operation)
    EmailMailboxOperationJob.perform_later(result.operation.id)
    render_operation(result.operation, status: result.http_status)
  end

  private

  def authorize_mailbox_action
    authorize @conversation, :mailbox_action?
  end

  def ensure_mailbox_actions_enabled
    return if Current.account.feature_enabled?('email_mailbox_actions')

    render json: { error_code: 'mailbox_actions_disabled' }, status: :forbidden
  end

  def permitted_params
    params.require(:mailbox_operation).permit(:action, :idempotency_key)
  end

  def render_error(result)
    render json: { error_code: result.error_code }, status: result.http_status
  end

  def render_operation(operation, status: :ok)
    render json: with_mailbox_state(operation: operation.summary), status: status
  end

  # These two responses build mailbox state directly rather than through
  # Imap::ConversationMailboxData, so they need the same gate or they reintroduce exactly what that
  # gate removes. The key is omitted rather than set to null because the dashboard tests for its
  # presence with hasOwnProperty.
  def with_mailbox_state(payload)
    state = publishable_mailbox_state
    return payload if state.nil?

    payload.merge(mailbox_state: state)
  end

  def publishable_mailbox_state
    return nil unless provider_mutation_allowed?

    state = Imap::ConversationMailboxState.new(conversation: @conversation)
    state.actionable? ? state.to_h : nil
  end

  def provider_mutation_allowed?
    channel = @conversation.inbox.channel
    channel.respond_to?(:mailbox_sync) && channel.mailbox_sync.provider_mutation_allowed?
  end
end
