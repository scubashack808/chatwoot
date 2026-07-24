# Imap::FetchedMessage carries one fetched message together with where the server says it lives.
#
# The fetch services used to return a bare Mail object, which meant the only durable handle on a
# message was its RFC Message-ID. This value object adds the server coordinates that survive a
# move: exact mailbox, UIDVALIDITY generation, UID, the mailbox's special-use roles, and a
# provider-stable id when the server advertises one.
#
# It deliberately exposes no sequence number. Sequence numbers are positional and shift on every
# expunge, so they are used only in-flight and never travel with the message.
class Imap::FetchedMessage
  attr_reader :mail, :mailbox, :uidvalidity, :uid, :roles, :provider_id

  delegate :message_id, :from, :to, :subject, :date, to: :mail

  # rubocop:disable Metrics/ParameterLists -- these are the named fields of a value object
  def initialize(mail:, mailbox:, uidvalidity:, uid:, roles: [], provider_id: nil)
    @mail = mail
    @mailbox = mailbox.to_s
    @uidvalidity = uidvalidity.to_i
    @uid = uid.to_i
    @roles = Array(roles).map(&:to_s)
    @provider_id = provider_id
  end
  # rubocop:enable Metrics/ParameterLists

  def to_identity
    Imap::MessageIdentity.build(
      mailbox: mailbox,
      uidvalidity: uidvalidity,
      uid: uid,
      roles: roles,
      provider_id: provider_id
    )
  end
end
