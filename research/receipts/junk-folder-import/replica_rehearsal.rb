# Replica rehearsal for the Junk folder import, against a real Dovecot (no IMAP mocks).
#
# Replica: dovecot/dovecot 2.4 in Docker with replica-dovecot.conf (this directory) mounted as
# conf.d/99-sandbox.conf, IMAP on 127.0.0.1:31143, any user with password "replicapass".
#
#   docker run -d --name junk-replica-dovecot -e 'USER_PASSWORD={PLAIN}replicapass' \
#     -v "$PWD/research/receipts/junk-folder-import/replica-dovecot.conf:/etc/dovecot/conf.d/99-sandbox.conf" \
#     -p 127.0.0.1:31143:31143 dovecot/dovecot:latest
#   RAILS_ENV=test POSTGRES_DATABASE=chatwoot_junk_replica \
#     bundle exec rails runner research/receipts/junk-folder-import/replica_rehearsal.rb
#
# Use a database of its own: it leaves its records behind, which would pollute the spec database.
# It writes only to that database and to a throwaway replica mailbox, and prints PASS/FAIL per
# acceptance term from runlog.md.
require 'net/imap'

# The test environment queues jobs without running them, which would let the notification check
# pass vacuously (the listener runs from a queued event job). Run every job inline instead.
class ReplicaInlineAdapter < ActiveJob::QueueAdapters::InlineAdapter
  def enqueue_at(job, _timestamp) = enqueue(job)
end
ActiveJob::Base.queue_adapter = ReplicaInlineAdapter.new

IMAP_HOST = '127.0.0.1'.freeze
IMAP_PORT = 31_143
IMAP_PASSWORD = 'replicapass'.freeze
LOGIN = "junk-#{SecureRandom.hex(4)}@replica.test".freeze

RESULTS = [] # rubocop:disable Style/MutableConstant
def check(term, label, condition)
  RESULTS << condition
  puts "#{condition ? 'PASS' : 'FAIL'} #{term} #{label}"
end

def imap
  client = Net::IMAP.new(IMAP_HOST, port: IMAP_PORT)
  client.login(LOGIN, IMAP_PASSWORD)
  yield client
ensure
  client&.logout
end

def append(folder, message_id, subject:, in_reply_to: nil)
  mail = Mail.new(from: 'sender@outside.test', to: LOGIN, subject: subject, body: "body of #{subject}",
                  message_id: "<#{message_id}>")
  mail.in_reply_to = "<#{in_reply_to}>" if in_reply_to
  imap { |c| c.append(folder, mail.to_s, [], Time.current) }
end

def folder_state(folder)
  imap do |c|
    c.examine(folder)
    uids = c.uid_search(['ALL'])
    seen = uids.empty? ? [] : c.uid_fetch(uids, ['FLAGS']).select { |d| d.attr['FLAGS'].include?(:Seen) }
    { count: uids.length, seen: seen.length }
  end
end

def junk_run(channel) = Imap::JunkImportService.new(channel: channel).perform

account = Account.create!(name: 'Junk replica')
account.enable_features!(:email_mailbox_actions)
channel = Channel::Email.create!(
  account: account, email: LOGIN, imap_enabled: true, imap_address: IMAP_HOST, imap_port: IMAP_PORT,
  imap_login: LOGIN, imap_password: IMAP_PASSWORD, imap_enable_ssl: false,
  mailbox_sync_config: { 'mode' => 'observe' }
)
inbox = Inbox.create!(account: account, channel: channel, name: 'Junk replica inbox')
agent = User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@replica.test", password: 'Password1!x', confirmed_at: Time.current)
AccountUser.create!(account: account, user: agent, role: :agent)
InboxMember.create!(inbox: inbox, user: agent)
setting = agent.notification_settings.find_by(account_id: account.id)
setting.selected_email_flags = [:email_conversation_creation]
setting.selected_push_flags = [:push_conversation_creation]
setting.save!

# A real conversation that junk will later reply into, and the server-side mail.
real = Conversation.create!(account: account, inbox: inbox, status: :resolved,
                            contact_inbox: ContactInbox.create!(inbox: inbox, source_id: 'real@outside.test',
                                                                contact: Contact.create!(account: account, email: 'real@outside.test')),
                            contact: Contact.find_by(email: 'real@outside.test', account: account))
Message.create!(account: account, inbox: inbox, conversation: real, message_type: :incoming, content: 'hello',
                source_id: 'real-thread@outside.test')
imap { |c| c.list('', '*') } # autocreate folders for this user
append('spam', 'junk-1@outside.test', subject: 'Cheap watches')
append('spam', 'junk-2@outside.test', subject: 'You won')
append('spam', 'junk-reply@outside.test', subject: 'Re: hello', in_reply_to: 'real-thread@outside.test')
append('Junk', 'decoy@outside.test', subject: 'Decoy in unflagged Junk')
append('INBOX', 'inbox-1@outside.test', subject: 'Ordinary mail')

puts "== replica folders: #{imap { |c| c.list('', '*').map { |f| "#{f.name}#{f.attr.grep(/Junk/).inspect}" } }.join(' ')}"

# T2 negative: two folders claim \Junk (the image's own Junk keeps its attribute in the ambiguous
# config). Nothing may be imported.
ambiguous = junk_run(channel)
puts "== ambiguous run: #{ambiguous.inspect}"
if ambiguous[:detail] == 'ambiguous'
  check('T2', 'two \\Junk folders and no override -> skipped ambiguous, nothing imported',
        ambiguous[:reason] == 'junk_folder_unavailable' && inbox.messages.where("source_id LIKE 'junk-%'").none?)
  channel.update!(mailbox_sync_config: { 'mode' => 'observe', 'folder_overrides' => { 'spam' => 'spam' } })
end

# T8 negative: gates.
account.disable_features!(:email_mailbox_actions)
check('T8', 'flag off -> skipped feature_disabled', junk_run(channel)[:reason] == 'feature_disabled')
account.enable_features!(:email_mailbox_actions)
channel.update!(mailbox_sync_config: channel.mailbox_sync_config.merge('mode' => 'off'))
check('T8', 'mode off -> skipped mailbox_sync_off', junk_run(channel)[:reason] == 'mailbox_sync_off')
channel.update!(mailbox_sync_config: channel.mailbox_sync_config.merge('mode' => 'observe'))

spam_before = folder_state('spam')
first = junk_run(channel)
puts "== first run: #{first.inspect}"
check('T1', 'imports the three spam-folder messages', first[:status] == 'completed' && first[:mailbox] == 'spam' && first[:imported] == 3)
check('T2', 'decoy unflagged Junk folder never read', inbox.messages.where(source_id: 'decoy@outside.test').none?)

junk_convs = inbox.conversations.where.not(id: real.id).to_a
spam_tab = Imap::MailboxRoleFilter.new(conversations: inbox.conversations, role: 'spam', account: account).perform
inbox_tab = Imap::MailboxRoleFilter.new(conversations: inbox.conversations.where.not(id: real.id), role: 'inbox',
                                        account: account).perform
check('T1', 'new junk conversations are on the Junk (spam) tab', junk_convs.length == 2 && junk_convs.all? { |c| spam_tab.exists?(c.id) })
check('T1', 'new junk conversations are not on the Inbox tab', junk_convs.none? { |c| inbox_tab.exists?(c.id) })
check('T1', 'identity records the real folder, UIDVALIDITY and spam role',
      junk_convs.all? do |c|
        identity = c.messages.incoming.last.imap_identity
        identity && identity.mailbox == 'spam' && identity.roles == ['spam'] && identity.uidvalidity.positive?
      end)

spam_after = folder_state('spam')
check('T3', "server untouched: spam count #{spam_before[:count]}->#{spam_after[:count]}, seen #{spam_before[:seen]}->#{spam_after[:seen]}",
      spam_before == spam_after && spam_after[:seen].zero?)

junk_convs.each(&:reload)
check('T5', 'created conversations are resolved and junk_import after commit', junk_convs.all? { |c| c.resolved? && c.junk_import? })
creation_notices = Notification.where(user: agent, notification_type: 'conversation_creation')
# Control: the setup conversation `real` was created normally and must have notified the agent,
# which proves the listener ran in this rehearsal and the junk check below is not vacuous.
check('T5', 'control: an ordinary conversation did notify the subscribed agent',
      creation_notices.exists?(primary_actor_type: 'Conversation', primary_actor_id: real.id))
check('T5', 'no conversation_creation notification for any junk conversation',
      creation_notices.where(primary_actor_type: 'Conversation', primary_actor_id: junk_convs.map(&:id)).none?)

real.reload
check('T6', 'junk reply threaded into the real conversation, which reopened and is not junk',
      real.messages.exists?(source_id: 'junk-reply@outside.test') && real.open? && !real.junk_import?)

second = junk_run(channel)
puts "== rerun: #{second.inspect}"
check('T4', 'rerun imports nothing', second[:imported].to_i.zero? && second[:already_present] == 3)

# T4: dedup before cap. With a cap of 1 and one new message behind three known ones, it still lands.
append('spam', 'junk-3@outside.test', subject: 'Late junk')
Imap::JunkImportService.send(:remove_const, :MAX_PER_CYCLE)
Imap::JunkImportService.const_set(:MAX_PER_CYCLE, 1)
capped = junk_run(channel)
check('T4', 'cap applies after dedup, so new mail behind known mail still imports', capped[:imported] == 1 && capped[:already_present] == 3)

# T8: ordinary INBOX ingestion still works with the gates on.
Inboxes::FetchImapEmailsJob.perform_now(channel)
inbox_conv = inbox.messages.find_by(source_id: 'inbox-1@outside.test')&.conversation
inbox_view = Imap::MailboxRoleFilter.new(conversations: inbox.conversations, role: 'inbox', account: account).perform
check('T8', 'INBOX fetch still creates an open conversation on the Inbox tab', inbox_conv&.open? && inbox_view.exists?(inbox_conv.id))

# T6 second half: ordinary mail threading into a junk conversation reopens it.
target = junk_convs.first
append('INBOX', 'inbox-reply@outside.test', subject: 'Re: junk', in_reply_to: target.messages.incoming.first.source_id)
Inboxes::FetchImapEmailsJob.perform_now(channel)
check('T6', 'inbox mail threading into a junk conversation reopens it', target.reload.open?)

# T7: restore a junk conversation to Inbox through the existing mailbox action.
restore_conv = junk_convs.last.reload
channel.update!(mailbox_sync_config: channel.mailbox_sync_config.merge('mode' => 'active'))
admin = User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@replica.test", password: 'Password1!x', confirmed_at: Time.current)
AccountUser.create!(account: account, user: admin, role: :administrator)
request = Imap::MailboxOperationRequest.new(conversation: restore_conv, user: admin, action: 'restore',
                                            idempotency_key: SecureRandom.uuid).perform
operation = request.operation
Imap::MailboxOperationExecutor.new(operation: operation).perform if operation
restore_conv.reload
moved_id = restore_conv.messages.incoming.first.source_id
inbox_ids = imap do |c|
  c.examine('INBOX')
  c.uid_search(['HEADER', 'Message-ID', moved_id])
end
check('T7', "restore operation #{operation&.reload&.status.inspect} moved the message to server INBOX", operation&.succeeded? && inbox_ids.one?)
check('T7', 'restored conversation reopened and junk_import cleared', restore_conv.open? && !restore_conv.junk_import?)
before = Message.count
Inboxes::FetchImapEmailsJob.perform_now(channel)
check('T7', 'next INBOX poll does not duplicate the restored message', Message.count == before)

puts "== #{RESULTS.count(true)}/#{RESULTS.length} checks passed"
exit(RESULTS.all? ? 0 : 1)
