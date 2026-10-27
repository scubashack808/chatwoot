# Forwarding for Messages::MessageBuilder: an agent sends one email of this conversation onward to
# new recipients, with a covering note (see Messages::ForwardEmailService for the mail itself).
module Messages::ForwardedMessageHelper
  private

  def forwarded_message_id
    content_attributes&.dig(:forwarded_message_id)
  end

  # Looked up inside this conversation only, so an id from anywhere else is not found.
  def forwarded_message
    @forwarded_message ||= @conversation.messages.where(private: false).find(forwarded_message_id)
  end

  def process_forwarded_email
    return if forwarded_message_id.blank?

    to_emails = @message.content_attributes[:to_emails] if email_inbox?
    # Without recipients the mailer falls back to the conversation's contact, which would send the
    # forward to the customer instead.
    raise StandardError, I18n.t('conversations.messages.forward.recipient_required') if to_emails.blank?

    note_text = process_liquid_in_email_body(normalize_email_body(@params[:content]))
    forward = Messages::ForwardEmailService.new(source: forwarded_message, note_html: render_email_html(note_text), note_text: note_text)
    @message.content = forward.content
    @message.content_attributes[:email] = forward.email_attributes(to: to_emails)
    attach_forwarded_files
  end

  # The original's files are attached by reusing their blobs: no download, no second copy.
  def attach_forwarded_files
    forwarded_message.attachments.each do |source_attachment|
      next unless source_attachment.file.attached?

      @message.attachments.build(account_id: @message.account_id, file: source_attachment.file.blob, file_type: source_attachment.file_type)
    end
  end
end
