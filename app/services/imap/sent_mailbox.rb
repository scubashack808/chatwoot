# The IMAP dialect for one inbox's Sent folder, on an already-connected client.
#
# Two things are structural here rather than conventional:
#
#   - the folder name is supplied by the caller from Imap::FolderDiscoveryService, so this class
#     has no folder name of its own and cannot guess one. The deployed code's hardcoded
#     'INBOX.Sent' is what produced 6,780 "Unknown Mailbox" warnings against Gmail;
#   - append_allowed is a constructor argument and #append refuses without it. Provider-managed
#     mode therefore cannot APPEND by accident, or by a later edit to a branch somewhere else.
#
# The folder is opened with EXAMINE, never SELECT, so reading Sent sets no flags and expunges
# nothing. APPEND is the one command that writes, and it addresses the mailbox by name rather than
# needing it selected.
class Imap::SentMailbox
  class AppendNotPermittedError < StandardError; end

  APPENDUID = 'APPENDUID'.freeze

  attr_reader :mailbox, :uidvalidity

  def initialize(client:, session:, mailbox:, append_allowed:)
    @client = client
    @session = session
    @mailbox = mailbox
    @append_allowed = append_allowed
  end

  def append_allowed?
    @append_allowed
  end

  def examine!
    session.command { client.examine(mailbox) }
    @uidvalidity = Array(client.responses('UIDVALIDITY')).last.to_i
    self
  end

  # Exact-header search. This is what runs BEFORE any append, and it is also the whole of
  # provider-managed mode: find the copy the provider already saved and attach to it.
  def search_message_id(message_id)
    Array(session.command { client.uid_search(['HEADER', 'Message-ID', message_id]) })
  end

  def search_since(date)
    Array(session.command { client.uid_search(['SINCE', date]) })
  end

  def fetch_headers(uids)
    Array(session.command { client.uid_fetch(uids, ['UID', 'BODY.PEEK[HEADER]']) })
  end

  def fetch_body(uid)
    session.command { client.uid_fetch(uid, ['BODY.PEEK[]']) }&.first&.attr&.dig('BODY[]')
  end

  # Returns the appended copy's location, from the server's own APPENDUID response where UIDPLUS
  # is advertised. Where it is not, the copy is confirmed by re-searching for its Message-ID and a
  # single unique match; anything else is left for the caller to treat as unresolved rather than
  # assumed.
  def append(source:, message_id:, internal_date:)
    raise AppendNotPermittedError, "APPEND is not permitted for #{mailbox}" unless append_allowed?

    response = session.command { client.append(mailbox, source, [:Seen], internal_date) }
    append_uid(response) || confirm_by_search(message_id)
  end

  private

  attr_reader :client, :session

  def append_uid(response)
    code = response.respond_to?(:data) ? response.data&.code : nil
    return nil if code.nil? || code.name.to_s.upcase != APPENDUID

    parse_append_uid(code.data)
  end

  # net-imap parses APPENDUID into a value object; older servers and older parsers hand back the
  # raw "uidvalidity uid" pair. Both are read here rather than assuming one shape.
  def parse_append_uid(data)
    return nil if data.nil?
    return { uidvalidity: data.uidvalidity.to_i, uid: assigned_uid(data) } if data.respond_to?(:uidvalidity)

    validity, uid = data.to_s.split
    return nil if uid.blank?

    { uidvalidity: validity.to_i, uid: uid.to_i }
  end

  def assigned_uid(data)
    return data.assigned_uid.to_i if data.respond_to?(:assigned_uid)

    Array(data.assigned_uids).first.to_i
  end

  def confirm_by_search(message_id)
    uids = search_message_id(message_id)
    return nil unless uids.one?

    { uidvalidity: uidvalidity, uid: uids.first.to_i }
  end
end
