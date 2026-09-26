#!/usr/bin/env ruby
# Run only through the native dummy environment wrapper and Rails runner.
expected_database = 'chatwoot_dummy_dev'
local_smtp_port = 1025
seed_text = 'Synthetic booking question. Can you confirm the test reservation?'
raise 'Unexpected database' unless ActiveRecord::Base.connection.current_database == expected_database
raise 'Unexpected database role' unless ActiveRecord::Base.connection.select_value('SELECT current_user') == 'chatwoot_dummy'

marker = ARGV.first
raise 'Invalid proof marker' if marker && !marker.match?(/\AVerify Chatwoot [a-z0-9]+\z/)

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
  raise 'Expected one synthetic account' unless Account.count == 1

  account = Account.find_by!(name: 'Chatwoot Dummy')
  user = User.find_by!(email: 'agent@chatwoot-dummy.test')
  raise 'Synthetic credential mismatch' unless user.valid_password?(ENV.fetch('DUMMY_PASSWORD'))
  raise 'Synthetic account access missing' unless account.account_users.exists?(user_id: user.id)

  inbox = account.inboxes.find_by!(name: 'Dummy Email')
  channel = inbox.channel
  raise 'Unsafe email channel' unless channel.is_a?(Channel::Email) && channel.email == 'support@chatwoot-dummy.test' &&
                                      !channel.imap_enabled && !channel.smtp_enabled

  smtp = ActionMailer::Base.smtp_settings
  raise 'Unsafe global SMTP' unless smtp[:address] == '127.0.0.1' && smtp[:port].to_i == local_smtp_port &&
                                    ActionMailer::Base.delivery_method == :smtp

  contact = account.contacts.find_by!(email: 'customer@chatwoot-dummy.test')
  seeds = inbox.messages.where(content: seed_text, message_type: :incoming, sender: contact)
  raise 'Synthetic incoming fixture is ambiguous' unless seeds.count == 1

  conversation = seeds.first.conversation
  raise 'Fixture must be open' unless conversation.open?

  result = { database: expected_database, account_id: account.id, user_id: user.id, inbox_id: inbox.id,
             conversation_id: conversation.id, display_id: conversation.display_id,
             customer_email: contact.email, sender_email: channel.email, seed_text: seed_text,
             authentication_valid: true, smtp_loopback: true, imap_disabled: true }
  if marker
    result[:messages] = conversation.messages.where(content: marker).map do |message|
      { id: message.id, content: message.content, message_type: message.message_type,
        private: message.private, status: message.status, conversation_id: message.conversation_id }
    end
  end
  puts "VERIFY_FIXTURE=#{result.to_json}"
end
