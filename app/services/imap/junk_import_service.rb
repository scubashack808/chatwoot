# Imports mail the server filed straight into its Junk folder, so it appears on the inbox's Junk tab
# (mailbox role `spam`).
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
  GMAIL_CAPABILITY = 'X-GM-EXT-1'.freeze
  GMAIL_MESSAGE_ID = 'X-GM-MSGID'.freeze
  # A message that cannot be imported (rejected sender, or one that keeps failing) is left alone for
  # longer than the SINCE window, so it is not re-fetched every minute and cannot hold the cap.
  SKIP_TTL = 3.days
  MAX_FAILURES = 3

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
    @gmail = session.command(&:capabilities).include?(GMAIL_CAPABILITY)
    junk = Imap::SentMailbox.new(client: client, session: session, mailbox: @mailbox, append_allowed: false).examine!
    uids = junk.search_since(since)
    @counts[:examined] = uids.length
    return [] if uids.empty?

    new_uids(junk, uids).first(MAX_PER_CYCLE).filter_map { |uid| fetch_message(client, session, junk, uid) }
  end

  def resolve_spam_role(client, session)
    folders = session.command { client.list('', '*') }
    Imap::FolderDiscoveryService.result_for(folders: folders, config: channel.mailbox_sync).for_role(SPAM_ROLE)
  end

  # Drops what Chatwoot already holds, what it has given up on, and repeats of one Message-ID within
  # this batch, all BEFORE the cap is applied, so a day with more junk than one cycle's cap still
  # drains over the following cycles instead of re-reading the same batch.
  def new_uids(junk, uids)
    seen = Set.new
    junk.fetch_headers(uids).filter_map do |data|
      message_id = Mail.read_from_string(data.attr['BODY[HEADER]'].to_s).message_id
      next tally(:missing_message_id) if message_id.blank?
      next tally(:already_present) if already_present?(message_id)
      next tally(:skipped) if skip_marked?(message_id)
      next tally(:duplicate_in_batch) unless seen.add?(message_id)

      data.attr['UID']
    end
  end

  # Counts and returns nil, so a filter_map block can count a drop without the count leaking out
  # as a value.
  def tally(key)
    @counts[key] += 1
    nil
  end

  def already_present?(message_id)
    channel.inbox.messages.exists?(source_id: message_id) ||
      Imap::DeletedMessageTracker.new(inbox: channel.inbox).deleted?(message_id)
  end

  # Gmail's stable message id is read with the body when the server offers it, as the INBOX fetch
  # does, so the identity is the same shape whichever folder the message arrived through.
  def fetch_message(client, session, junk, uid)
    attributes = @gmail ? ['BODY.PEEK[]', GMAIL_MESSAGE_ID] : ['BODY.PEEK[]']
    data = session.command { client.uid_fetch(uid, attributes) }&.first
    body = data&.attr&.dig('BODY[]')
    return if body.blank?

    Imap::FetchedMessage.new(
      mail: Mail.read_from_string(body), mailbox: @mailbox, uidvalidity: junk.uidvalidity, uid: uid, roles: [SPAM_ROLE],
      provider_id: data.attr[GMAIL_MESSAGE_ID]&.to_s
    )
  end

  # ImapMailbox returns early, creating nothing, for mail it rejects (an empty or own-address sender
  # is classic backscatter). That is permanent for this message, so it is marked straight away.
  def import(fetched_message)
    message_id = fetched_message.message_id
    Imap::ImapMailbox.new.process(fetched_message, channel, junk: true)
    return tally(:imported) if channel.inbox.messages.exists?(source_id: message_id)

    mark_skipped(message_id)
    tally(:rejected)
  rescue StandardError => e
    record_failure(message_id)
    tally(:failed)
    Rails.logger.error "[IMAP::JUNK_IMPORT] Could not import a Junk message for inbox #{channel.inbox.id}: #{e.class}"
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  def skip_marked?(message_id)
    Rails.cache.read(skip_key(message_id)).present?
  end

  def mark_skipped(message_id)
    Rails.cache.write(skip_key(message_id), true, expires_in: SKIP_TTL)
  end

  def record_failure(message_id)
    failures = Rails.cache.read(failure_key(message_id)).to_i + 1
    Rails.cache.write(failure_key(message_id), failures, expires_in: SKIP_TTL)
    mark_skipped(message_id) if failures >= MAX_FAILURES
  end

  def skip_key(message_id)
    "imap_junk_import:skip:#{channel.inbox.id}:#{Digest::SHA256.hexdigest(message_id.to_s)}"
  end

  def failure_key(message_id)
    "imap_junk_import:failures:#{channel.inbox.id}:#{Digest::SHA256.hexdigest(message_id.to_s)}"
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
