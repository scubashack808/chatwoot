#!/usr/bin/env ruby
# Forward fixture and checks. Run only through the native dummy environment wrapper and Rails runner,
# always as <action> <run tag> [arguments]. Each run gets its own conversation, so a run never
# depends on how many messages earlier runs left behind (the thread loads only its newest page).
#   seed               create the run's synthetic forward conversation and its messages (once per tag)
#   inspect MARKER...  read-only: the persisted messages carrying each marker
#   fail ID            mark one forward failed, as a delivery failure would
#   reply ID           feed a synthetic reply to that forward through the IMAP mailbox
#   rerender ID        read-only: render the forward again, the way Sent sync archives it
#   scope              POST a forward whose source belongs to another conversation
# Every result is one VERIFY_FORWARD=<json> line.
expected_database = 'chatwoot_dummy_dev'
local_smtp_port = 1025
run_tag = ARGV.second.to_s
raise 'Invalid run tag' unless run_tag.match?(/\A[0-9a-z]+\z/)

fixture_tag = "forward-v1-#{run_tag}"
source_message_id = "verify-forward-source-#{run_tag}@chatwoot-dummy.test"
vendor_email = 'vendor@chatwoot-dummy.test'
sender_email = 'support@chatwoot-dummy.test'
html_marker = 'Synthetic forward source body'
plain_text = 'Synthetic plain note for forwarding. No attachments.'
reply_text = 'Synthetic agent reply for forwarding.'
note_text = 'Synthetic private note; never forwardable.'
marker_pattern = /\AVerify Forward [a-z0-9]+ F[0-9]\z/
replier_email = 'forward-to-1@chatwoot-dummy.test'
# The smallest well-formed PDF: one empty page.
pdf_bytes = "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" \
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 72 72]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"

raise 'Unexpected database' unless ActiveRecord::Base.connection.current_database == expected_database
raise 'Unexpected database role' unless ActiveRecord::Base.connection.select_value('SELECT current_user') == 'chatwoot_dummy'
raise 'Expected one synthetic account' unless Account.count == 1

account = Account.find_by!(name: 'Chatwoot Dummy')
user = User.find_by!(email: 'agent@chatwoot-dummy.test')
inbox = account.inboxes.find_by!(name: 'Dummy Email')
channel = inbox.channel
raise 'Unsafe email channel' unless channel.is_a?(Channel::Email) && channel.email == sender_email &&
                                    !channel.imap_enabled && !channel.smtp_enabled

smtp = ActionMailer::Base.smtp_settings
raise 'Unsafe global SMTP' unless smtp[:address] == '127.0.0.1' && smtp[:port].to_i == local_smtp_port &&
                                  ActionMailer::Base.delivery_method == :smtp

find_conversation = lambda do
  inbox.conversations.find_by("additional_attributes->>'verify_fixture' = ?", fixture_tag)
end

describe_attachment = lambda do |attachment|
  blob = attachment.file.blob
  { blob_id: blob.id, filename: blob.filename.to_s, byte_size: blob.byte_size, checksum: blob.checksum }
end

describe_message = lambda do |message|
  attributes = message.content_attributes.with_indifferent_access
  html = attributes.dig(:email, :html_content, :full).to_s
  { id: message.id, conversation_id: message.conversation_id, message_type: message.message_type, private: message.private,
    status: message.status, source_id: message.source_id, content: message.content,
    forwarded_message_id: attributes[:forwarded_message_id], to_emails: attributes[:to_emails], cc_emails: attributes[:cc_emails],
    bcc_emails: attributes[:bcc_emails], subject: attributes.dig(:email, :subject), email_to: attributes.dig(:email, :to),
    external_error: attributes[:external_error], html_has_forward_marker: html.include?(Messages::ForwardEmailService::FORWARD_MARKER),
    html_has_source_body: html.include?(html_marker), attachments: message.attachments.map(&describe_attachment) }
end

fixture_summary = lambda do |conversation|
  messages = conversation.messages.order(:id)
  pick = ->(content) { messages.find { |message| message.content == content } }
  html_source = messages.find { |message| message.content_attributes.dig(:email, :subject) == 'Synthetic invoice 42' }
  { database: expected_database, account_id: account.id, inbox_id: inbox.id, conversation_id: conversation.id,
    display_id: conversation.display_id, vendor_email: vendor_email, sender_email: sender_email, html_marker: html_marker,
    html_source: describe_message.call(html_source), plain_source: describe_message.call(pick.call(plain_text)),
    outgoing_reply: describe_message.call(pick.call(reply_text)), private_note: describe_message.call(pick.call(note_text)),
    message_count: messages.count }
end

action = ARGV.first
args = ARGV.drop(2)
result = case action
         when 'seed'
           conversation = find_conversation.call
           created = conversation.nil?
           if created
             ActiveRecord::Base.transaction do
               contact_inbox = ContactInboxWithContactBuilder.new(
                 source_id: "dummy-vendor-#{run_tag}", inbox: inbox, hmac_verified: true,
                 contact_attributes: { name: 'Synthetic Vendor', email: vendor_email }
               ).perform
               vendor = contact_inbox.contact
               conversation = Conversation.create!(account: account, inbox: inbox, status: :open, assignee: user, contact: vendor,
                                                   contact_inbox: contact_inbox,
                                                   additional_attributes: { 'mail_subject' => 'Synthetic invoice 42',
                                                                            'verify_fixture' => fixture_tag })
               html = "<div><p>#{html_marker}.</p><p><b>Invoice 42</b> is attached as a PDF and an image.</p></div>"
               source = Message.create!(
                 content: "#{html_marker}. Invoice 42 is attached as a PDF and an image.", account: account, inbox: inbox,
                 conversation: conversation, sender: vendor, message_type: :incoming, source_id: source_message_id,
                 content_attributes: { email: { subject: 'Synthetic invoice 42', from: [vendor_email], to: [sender_email],
                                                date: 'Mon, 27 Oct 2026 09:00:00 +0000', message_id: source_message_id,
                                                html_content: { full: html, reply: html },
                                                text_content: { full: "#{html_marker}.\nInvoice 42 is attached as a PDF and an image." } } }
               )
               source.attachments.create!(account_id: account.id, file_type: :file,
                                          file: { io: StringIO.new(pdf_bytes), filename: 'synthetic-invoice-42.pdf',
                                                  content_type: 'application/pdf' })
               source.attachments.create!(account_id: account.id, file_type: :image,
                                          file: { io: Rails.root.join('spec/assets/avatar.png').open, filename: 'synthetic-logo.png',
                                                  content_type: 'image/png' })
               Message.create!(content: plain_text, account: account, inbox: inbox, conversation: conversation, sender: vendor,
                               message_type: :incoming, content_attributes: { email: { subject: 'Synthetic plain note',
                                                                                       from: [vendor_email], to: [sender_email] } })
               Message.create!(content: note_text, account: account, inbox: inbox, conversation: conversation, sender: user,
                               message_type: :outgoing, private: true)
             end
             # A real agent reply, built the way the composer's request builds one, so it is delivered to Mailpit.
             Messages::MessageBuilder.new(user, conversation, ActionController::Parameters.new(content: reply_text)).perform
           end
           fixture_summary.call(conversation.reload).merge(created: created)
         when 'inspect'
           markers = args
           raise 'Invalid proof marker' unless markers.present? && markers.all? { |marker| marker.match?(marker_pattern) }

           ActiveRecord::Base.transaction do
             ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
             conversation = find_conversation.call
             raise 'Forward fixture missing; seed first' unless conversation

             fixture_summary.call(conversation).merge(
               markers: markers.index_with do |marker|
                 inbox.messages.where('content LIKE ?', "%#{marker}%").order(:id).map(&describe_message)
               end
             )
           end
         when 'fail'
           forward = inbox.messages.find(args.first)
           raise 'Only a forward may be failed here' unless forward.email_forward?

           Messages::StatusUpdateService.new(forward, 'failed', 'Synthetic delivery failure').perform
           describe_message.call(forward.reload)
         when 'reply'
           forward = inbox.messages.find(args.first)
           raise 'Only a forward may be replied to here' unless forward.email_forward? && forward.source_id.present?

           source_conversation = forward.conversation
           before = { conversations: inbox.conversations.count, source_messages: source_conversation.messages.count }
           # Reply where the forward asked for replies: its own Reply-To, as delivered.
           reply_address = ConversationReplyMailer.email_reply(forward).message.reply_to.first
           mail = Mail.new do
             from replier_email
             to reply_address
             subject "Re: #{forward.content_attributes.dig(:email, :subject)}"
             message_id "<verify-forward-reply-#{forward.id}@chatwoot-dummy.test>"
             in_reply_to "<#{forward.source_id}>"
             references "<#{forward.source_id}>"
             content_type 'text/plain; charset=UTF-8'
             body 'Synthetic reply to a forward.'
           end
           # The ActionMailbox threading strategies (forwarded-mail inboxes) must not claim it either;
           # NewConversationStrategy is left out because it creates records.
           threading = [Mailbox::ConversationFinderStrategies::ReceiverUuidStrategy,
                        Mailbox::ConversationFinderStrategies::InReplyToStrategy,
                        Mailbox::ConversationFinderStrategies::ReferencesStrategy]
           action_mailbox_match = Mailbox::ConversationFinder.new(mail, strategies: threading).find
           Imap::ImapMailbox.new.process(mail, channel)
           reply = inbox.messages.where(source_id: "verify-forward-reply-#{forward.id}@chatwoot-dummy.test").last
           { before: before,
             after: { conversations: inbox.conversations.count, source_messages: source_conversation.messages.count },
             reply_address: reply_address, action_mailbox_conversation_id: action_mailbox_match&.id,
             reply_message_id: reply&.id, reply_conversation_id: reply&.conversation_id, reply_content: reply&.content,
             reply_contact_email: reply&.conversation&.contact&.email, source_conversation_id: source_conversation.id }
         when 'rerender'
           forward = inbox.messages.find(args.first)
           mail = ConversationReplyMailer.email_reply(forward).message
           html = mail.html_part&.decoded || mail.body.decoded
           { id: forward.id, subject: mail.subject, to: mail.to, cc: mail.cc, reply_to: mail.reply_to, message_id: mail.message_id,
             in_reply_to: mail.in_reply_to, references: mail.references,
             html: html, attachments: mail.attachments.map(&:filename) }
         when 'scope'
           conversation = find_conversation.call
           foreign = account.conversations.where.not(id: conversation.id).joins(:messages).merge(Message.where(private: false)).first
           foreign_message = foreign.messages.where(private: false).first
           before = Message.count
           session = ActionDispatch::Integration::Session.new(Rails.application)
           session.host! 'localhost'
           session.post("/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
                        params: { content: 'Synthetic cross-conversation forward', to_emails: replier_email,
                                  content_attributes: { forwarded_message_id: foreign_message.id } },
                        headers: { 'api_access_token' => user.access_token.token }, as: :json)
           { status: session.response.status, error: session.response.parsed_body['error'], foreign_message_id: foreign_message.id,
             messages_created: Message.count - before }
         else
           raise 'Unknown action'
         end
puts "VERIFY_FORWARD=#{result.to_json}"
