# Selects the exact mailbox command dialect for one connected IMAP client.
#
# The command implementations are intentionally limited to Archive, Trash, Spam, and Restore.
# They address messages only by the PR 04 UID identity and never provide a sequence-number or
# COPY/STORE/EXPUNGE fallback.
class Imap::MailboxCommand
  RESTORE_TARGET = Imap::MailboxSyncConfig::RESTORE_TARGET
  GMAIL_CAPABILITY = 'X-GM-EXT-1'.freeze
  INBOX_LABEL = '\\Inbox'.freeze

  Result = Struct.new(
    :status,
    :target_mailbox,
    :target_uidvalidity,
    :target_uid,
    :target_roles,
    :detail,
    :preserve_source,
    keyword_init: true
  )

  def self.dialect_for(client, capabilities: nil)
    advertised = capabilities || client.capabilities
    advertised.include?(GMAIL_CAPABILITY) ? Gmail : Standard
  end
end
