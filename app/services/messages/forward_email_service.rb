# Builds the outgoing email for a forward: the agent's covering note, a Gmail-style attribution
# block and the original message's body, plus the Fwd: subject.
#
# Everything is derived from stored data, so a later re-render of the forward (Sent sync archives
# a copy by rendering email_reply again) produces the same mail that was delivered.
class Messages::ForwardEmailService
  FORWARD_MARKER = '---------- Forwarded message ---------'.freeze
  SUBJECT_PREFIX = 'Fwd:'.freeze
  # Fwd:, Fw: and FWD: all count as already forwarded, so forwarding a forward never doubles it.
  FORWARDED_SUBJECT_PATTERN = /\Afwd?:/i

  pattr_initialize [:source!, :note_html!, :note_text!]

  # The content_attributes[:email] hash for the forward.
  def email_attributes(to:)
    {
      subject: subject,
      to: to,
      html_content: { full: html_body, reply: html_body },
      text_content: { full: text_body, reply: text_body }
    }
  end

  # The message's plain content: the note and the attribution block, which is what the
  # conversation list previews. The original body lives in the email attributes.
  def content
    [note_text.presence, attribution_lines.join("\n")].compact.join("\n\n")
  end

  private

  def subject
    original = header_subject
    original.match?(FORWARDED_SUBJECT_PATTERN) ? original : "#{SUBJECT_PREFIX} #{original}"
  end

  def html_body
    attribution = attribution_lines.map { |line| ERB::Util.html_escape(line) }.join('<br>')

    <<~HTML.squish
      <div dir="auto">#{note_html}</div><br>
      <div class="gmail_quote gmail_quote_container">
      <div class="gmail_attr">#{attribution}<br></div><br>
      #{original_html}
      </div>
    HTML
  end

  def text_body
    [note_text.presence, attribution_lines.join("\n"), original_text].compact.join("\n\n")
  end

  def attribution_lines
    [
      FORWARD_MARKER,
      "From: #{header_from}",
      "Date: #{header_date}",
      "Subject: #{header_subject}",
      "To: #{header_to}"
    ]
  end

  def original_html
    html = source_email.dig(:html_content, :full)
    return html if html.present?

    "<p>#{ERB::Util.html_escape(original_text).gsub("\n", '<br>')}</p>"
  end

  def original_text
    source_email.dig(:text_content, :full).presence || source.content.to_s
  end

  def header_from
    address = Array(source_email[:from]).first || source.sender.try(:email)
    name = source.sender.try(:available_name) || source.sender.try(:name)
    return address.to_s if name.blank? || name == address

    "#{name} <#{address}>"
  end

  def header_date
    source_email[:date].presence || source.created_at.rfc2822
  end

  def header_subject
    source_email[:subject].presence || source.conversation.additional_attributes['mail_subject'].to_s
  end

  def header_to
    recipients = source_email[:to].presence || source.content_attributes[:to_emails].presence
    Array(recipients || source.conversation.contact.email).join(', ')
  end

  def source_email
    @source_email ||= (source.content_attributes[:email] || {}).with_indifferent_access
  end
end
