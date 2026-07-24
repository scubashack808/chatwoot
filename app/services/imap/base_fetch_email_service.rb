require 'net/imap'

class Imap::BaseFetchEmailService
  MAX_MESSAGES_PER_SYNC = 500

  pattr_initialize [:channel!, :interval]

  # This class owns how to authenticate against a given channel's IMAP server, so it is also the
  # entry point other mailbox work uses to borrow a connected client.
  def self.for(channel, interval: nil)
    klass = if channel.microsoft?
              Imap::MicrosoftFetchEmailService
            elsif channel.google?
              Imap::GoogleFetchEmailService
            else
              Imap::FetchEmailService
            end

    klass.new(channel: channel, interval: interval)
  end

  def fetch_emails
    # Override this method
  end

  # Runs a block against a connected, authenticated client under the same lease and
  # guaranteed-cleanup session that perform uses. Used by work that is not a message fetch, such
  # as folder discovery.
  def with_connection
    Imap::Lease.with_lease(inbox_id: channel.inbox.id) do |lease|
      Imap::Session.run(lease: lease) do |session|
        @session = session
        yield imap_client, session
      end
    end
  end

  # All per-inbox IMAP work runs under one owner-token lease and one guaranteed-cleanup session.
  # The lease stops concurrent workers from multiplying connections against the same mailbox. The
  # session guarantees the socket is closed on every exit path, including a failure during
  # connect, authenticate, or select, which the previous shape skipped entirely.
  def perform
    Imap::Lease.with_lease(inbox_id: channel.inbox.id) do |lease|
      Imap::Session.run(lease: lease) do |session|
        @session = session
        fetch_emails
      end
    end
  end

  private

  attr_reader :session

  def authentication_type
    # Override this method
  end

  def imap_password
    # Override this method
  end

  def imap_client
    @imap_client ||= build_imap_client
  end

  def mail_info_logger(inbound_mail, uid)
    return if Rails.env.test?

    Rails.logger.info("
      #{channel.provider} Email id: #{inbound_mail.from} - message_source_id: #{inbound_mail.message_id} - uid: #{uid}")
  end

  def email_already_present?(channel, message_id)
    # exists? avoids Message's default_scope ORDER BY, which full-scans large inboxes
    channel.inbox.messages.exists?(source_id: message_id) || deleted_message_tracker.deleted?(message_id)
  end

  def deleted_message_tracker
    @deleted_message_tracker ||= Imap::DeletedMessageTracker.new(inbox: channel.inbox)
  end

  def fetch_mail_for_channel
    message_ids_with_uid = fetch_message_ids_with_uid
    message_ids_with_uid.filter_map do |message_id_with_uid|
      process_message_id(message_id_with_uid)
    end
  end

  def process_message_id(message_id_with_uid)
    uid, message_id = message_id_with_uid

    if message_id.blank?
      Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Empty message id for #{channel.email} with uid <#{uid}>."
      return
    end

    return if email_already_present?(channel, message_id)

    # Fetch the original mail content by UID, which is stable across expunges.
    # BODY.PEEK[] avoids RFC822 parser failures seen with some IMAP servers.
    client = imap_client
    data = session.command { client.uid_fetch(uid, body_fetch_attributes) }&.first

    mail_str = data&.attr&.dig('BODY[]')

    if mail_str.blank?
      Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Fetch failed for #{channel.email} with message-id <#{message_id}>."
      return
    end

    inbound_mail = build_mail_from_string(mail_str)
    mail_info_logger(inbound_mail, uid)

    build_fetched_message(inbound_mail, uid, data)
  end

  # The message plus where the server says it lives. The mailbox is INBOX here because that is
  # what this service selects; other roles are read by their own callers.
  def build_fetched_message(inbound_mail, uid, data)
    Imap::FetchedMessage.new(
      mail: inbound_mail,
      mailbox: mailbox_name,
      uidvalidity: current_uidvalidity,
      uid: uid,
      roles: mailbox_roles,
      provider_id: data.attr['X-GM-MSGID']&.to_s
    )
  end

  # Sends a UID FETCH to retrieve data associated with a message in the mailbox.
  # You can send batches of UIDs in `.uid_fetch`.
  def fetch_message_ids_with_uid
    uids = fetch_available_uids

    Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Fetching mails from #{channel.email}, found #{uids.length}."

    message_ids_with_uid = []
    uids.each_slice(MAX_MESSAGES_PER_SYNC).each do |batch|
      append_message_ids_for_batch(batch, message_ids_with_uid)
      if message_ids_with_uid.length >= MAX_MESSAGES_PER_SYNC
        Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Reached MAX_MESSAGES_PER_SYNC=#{MAX_MESSAGES_PER_SYNC} for #{channel.email}, stopping sync."
        break
      end
    end

    message_ids_with_uid
  end

  def append_message_ids_for_batch(batch, message_ids_with_uid)
    # Fetch only message-id only without mail body or contents.
    client = imap_client
    batch_message_ids = session.command { client.uid_fetch(batch, header_fetch_attributes) }
    Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Fetching the batch for #{channel.email}. Found #{batch_message_ids&.length} messages."

    # .fetch returns an array of Net::IMAP::FetchData or nil
    # (instead of an empty array) if there is no matching message.
    if batch_message_ids.blank?
      Rails.logger.info "[IMAP::FETCH_EMAIL_SERVICE] Fetching the batch failed for #{channel.email}."
      return
    end

    batch_message_ids.each do |data|
      entry = build_message_id_entry(data)
      next if entry.nil?

      message_ids_with_uid.push(entry)
      break if message_ids_with_uid.length >= MAX_MESSAGES_PER_SYNC
    end
  end

  def build_message_id_entry(data)
    mail = build_mail_from_string(data.attr['BODY[HEADER]'])
    return nil if MailPresenter.new(mail, channel.account).notification_email_from_chatwoot?

    message_id = mail.message_id
    return nil if message_id.blank?
    return nil if email_already_present?(channel, message_id)

    # data.seqno exists but is deliberately never used or stored: it is positional and shifts on
    # every expunge. The UID is the stable handle.
    [data.attr['UID'], message_id]
  end

  # Sends a UID SEARCH for messages since the given date and returns UIDs.
  def fetch_available_uids
    client = imap_client
    Array(session.command { client.uid_search(['SINCE', since]) })
  end

  def header_fetch_attributes
    gmail_extensions? ? ['UID', 'BODY.PEEK[HEADER]', 'X-GM-MSGID'] : ['UID', 'BODY.PEEK[HEADER]']
  end

  def body_fetch_attributes
    gmail_extensions? ? ['BODY.PEEK[]', 'X-GM-MSGID'] : ['BODY.PEEK[]']
  end

  # Gmail is selected by the advertised capability, never by the Chatwoot provider field, which is
  # blank on every live channel including the Gmail-hosted one.
  def gmail_extensions?
    return @gmail_extensions if defined?(@gmail_extensions)

    @gmail_extensions = imap_client.capabilities.include?('X-GM-EXT-1')
  rescue StandardError
    @gmail_extensions = false
  end

  def mailbox_name
    'INBOX'
  end

  def mailbox_roles
    ['inbox']
  end

  # The UIDVALIDITY of the selected mailbox. Every UID is only meaningful inside its generation,
  # so it is captured with the UID and stored alongside it.
  def current_uidvalidity
    @current_uidvalidity ||= Array(imap_client.responses('UIDVALIDITY')).last
  end

  # The raw connection is handed to the session the instant it exists, before authentication runs,
  # so that a failure during authenticate or select still leaves the session something to close.
  def build_imap_client
    imap = session.connect do
      Net::IMAP.new(channel.imap_address, port: channel.imap_port, ssl: channel.imap_enable_ssl)
    end

    session.command { Imap::Authentication.authenticate!(imap, authentication_type, channel.imap_login, imap_password) }
    session.command { imap.select('INBOX') }

    imap
  end

  def build_mail_from_string(raw_email_content)
    Mail.read_from_string(raw_email_content)
  end

  def since
    previous_day = Time.zone.today - (interval || 1).to_i
    previous_day.strftime('%d-%b-%Y')
  end
end
