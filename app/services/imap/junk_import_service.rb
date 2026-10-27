# Imports mail the server filed straight into its Junk folder, so it appears on the inbox's Spam tab.
#
# Ingestion only ever selects INBOX, and reconciliation only re-tags messages Chatwoot already has,
# so a message the server's spam filter delivered directly to Junk never reached Chatwoot at all.
# This reads the exact folder discovery resolves for the spam role (special-use \Junk, or an
# administrator override) and never guesses a name: on cPanel that is INBOX.spam, on Gmail
# [Gmail]/Spam.
#
# The folder is opened with EXAMINE and bodies are read with BODY.PEEK, so nothing on the server
# changes, which is why observe mode may run it. Messages are collected under the lease and
# processed after the connection closes, the same split Inboxes::FetchImapEmailsJob uses, so slow
# message processing cannot outlive the lease.
class Imap::JunkImportService
  SPAM_ROLE = 'spam'.freeze
  MAX_PER_CYCLE = 100

  def initialize(channel:, interval: 1)
    @channel = channel
    @interval = interval
    @counts = Hash.new(0)
  end

  def perform
    return skipped('feature_disabled') unless channel.account.feature_enabled?('email_mailbox_actions')
    return skipped('mailbox_sync_off') if channel.mailbox_sync.off?

    fetched = Imap::BaseFetchEmailService.for(channel).with_connection { |client, session| collect(client, session) }
    return fetched if fetched.is_a?(Hash)

    fetched.each { |fetched_message| import(fetched_message) }
    completed
  end

  private

  attr_reader :channel, :interval

  def collect(client, session)
    role = resolve_spam_role(client, session)
    return skipped('junk_folder_unavailable', detail: role.status) unless role.available?

    @mailbox = role.selected
    junk = Imap::SentMailbox.new(client: client, session: session, mailbox: @mailbox, append_allowed: false).examine!
    uids = junk.search_since(since)
    @counts[:examined] = uids.length
    return [] if uids.empty?

    new_uids(junk, uids).first(MAX_PER_CYCLE).filter_map { |uid| fetch_message(junk, uid) }
  end

  def resolve_spam_role(client, session)
    folders = session.command { client.list('', '*') }
    Imap::FolderDiscoveryService.result_for(folders: folders, config: channel.mailbox_sync).for_role(SPAM_ROLE)
  end

  # Drops what Chatwoot already holds BEFORE the cap is applied, so a day with more junk than one
  # cycle's cap still drains over the following cycles instead of re-reading the same newest batch.
  def new_uids(junk, uids)
    junk.fetch_headers(uids).filter_map do |data|
      message_id = Mail.read_from_string(data.attr['BODY[HEADER]'].to_s).message_id
      next if message_id.blank?
      next @counts[:already_present] += 1 if already_present?(message_id)

      data.attr['UID']
    end
  end

  def already_present?(message_id)
    channel.inbox.messages.exists?(source_id: message_id) ||
      Imap::DeletedMessageTracker.new(inbox: channel.inbox).deleted?(message_id)
  end

  def fetch_message(junk, uid)
    body = junk.fetch_body(uid)
    return if body.blank?

    Imap::FetchedMessage.new(
      mail: Mail.read_from_string(body), mailbox: @mailbox, uidvalidity: junk.uidvalidity, uid: uid, roles: [SPAM_ROLE]
    )
  end

  def import(fetched_message)
    Imap::ImapMailbox.new.process(fetched_message, channel, junk: true)
    @counts[:imported] += 1
  rescue StandardError => e
    @counts[:failed] += 1
    Rails.logger.error "[IMAP::JUNK_IMPORT] Could not import a Junk message for inbox #{channel.inbox.id}: #{e.class}"
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  def completed
    { status: 'completed', reason: nil, inbox_id: channel.inbox.id, mailbox: @mailbox, **@counts }
  end

  def skipped(reason, detail: nil)
    { status: 'skipped', reason: reason, detail: detail, inbox_id: channel.inbox.id }
  end

  def since
    (Time.zone.today - interval.to_i).strftime('%d-%b-%Y')
  end
end
