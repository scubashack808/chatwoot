class Api::V1::Accounts::Conversations::MailboxOperationsController < Api::V1::Accounts::Conversations::BaseController
  before_action :authorize_mailbox_action, only: :create

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

  def permitted_params
    params.require(:mailbox_operation).permit(:action, :idempotency_key)
  end

  def render_error(result)
    render json: { error_code: result.error_code }, status: result.http_status
  end

  def render_operation(operation, status: :ok)
    render json: {
      operation: operation.summary,
      mailbox_state: Imap::ConversationMailboxState.new(conversation: @conversation).to_h
    }, status: status
  end
end
