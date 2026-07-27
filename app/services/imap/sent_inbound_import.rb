# M06: import replies that were sent from another mail client into the conversation they belong to.
#
# The deployed implementation polled a guessed folder. This reads the exact folder discovery
# resolved, and it imports a message only when Imap::SentThreadResolver can point at one existing
# conversation. An unthreaded or ambiguous message is counted and left alone: the plan's non-goals
# list forbids "creation of Chatwoot conversations from unthreaded external Sent mail", so there is
# no contact creation path in this class at all.
#
# The imported message is outgoing and carries its own Message-ID as source_id, which is also what
# stops Chatwoot from mailing it back out: Base::SendOnChannelService treats a message with a
# source_id as one that originated from the channel and refuses to send it.
class Imap::SentInboundImport
  include MailboxSanitizer

  MAX_PER_CYCLE = 100

  def initialize(channel:, sent_mailbox:, interval: 1)
    @channel = channel
    @sent_mailbox = sent_mailbox
    @interval = interval
    @counts = Hash.new(0)
  end

  def perform
    uids = sent_mailbox.search_since(since).last(MAX_PER_CYCLE)
    return @counts.merge(examined: 0) if uids.empty?

    sent_mailbox.fetch_headers(uids).each { |data| consider(data) }
    @counts.merge(examined: uids.length)
  end

  private

  attr_reader :channel, :sent_mailbox, :interval

  def consider(data)
    header = Mail.read_from_string(data.attr['BODY[HEADER]'].to_s)
    message_id = sanitize_mailbox_value(header.message_id)
    return if message_id.blank?
    return @counts[:already_present] += 1 if already_present?(message_id)

    thread(header, data.attr['UID'], message_id)
  rescue StandardError => e
    @counts[:failed] += 1
    Rails.logger.error "[IMAP::SENT_SYNC] Could not import a Sent message for inbox #{channel.inbox.id}: #{e.class}"
  end

  def thread(header, uid, message_id)
    resolution = Imap::SentThreadResolver.new(inbox: channel.inbox, mail: header).perform
    return @counts[resolution.reason.to_sym] += 1 if resolution.conversation.nil?

    import(resolution.conversation, uid, message_id)
  end

  def already_present?(message_id)
    channel.inbox.messages.exists?(source_id: message_id) ||
      Imap::DeletedMessageTracker.new(inbox: channel.inbox).deleted?(message_id)
  end

  def import(conversation, uid, message_id)
    body = sent_mailbox.fetch_body(uid)
    return if body.blank?

    mail = Mail.read_from_string(body)
    presenter = MailPresenter.new(mail, channel.account)
    message = create_message(conversation, presenter, message_id)
    message.write_imap_sent_sync!(
      Imap::SentSyncState.build(state: Imap::SentSyncState::SYNCED),
      identity: Imap::MessageIdentity.build(mailbox: sent_mailbox.mailbox, uidvalidity: sent_mailbox.uidvalidity, uid: uid, roles: ['sent'])
    )
    @counts[:imported] += 1
  end

  # Outgoing, and with no sender: the message was written by a human in another client and Chatwoot
  # cannot honestly attribute it to one of its agents.
  def create_message(conversation, presenter, message_id)
    conversation.messages.create!(
      sanitize_mailbox_value(
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        message_type: 'outgoing',
        content_type: 'incoming_email',
        source_id: message_id,
        content: mail_body(presenter)&.truncate(150_000),
        content_attributes: { email: presenter.serialized_data, cc_email: presenter.cc, bcc_email: presenter.bcc }
      )
    )
  end

  def mail_body(presenter)
    return presenter.text_content[:reply] if presenter.text_content.present?

    presenter.html_content[:reply] if presenter.html_content.present?
  end

  def since
    (Time.zone.today - interval.to_i).strftime('%d-%b-%Y')
  end
end
