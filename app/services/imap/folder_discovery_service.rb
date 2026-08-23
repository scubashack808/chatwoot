# Imap::FolderDiscoveryService reads the server's own SPECIAL-USE metadata and reports, per role,
# whether exactly one folder is usable.
#
# Folder behaviour cannot be selected from channel.provider: every live production channel reports
# a blank provider, including the Gmail hosted one. The server's LIST response is the only source,
# with an explicit administrator override where discovery is absent or ambiguous.
#
# The zero / one / multiple outcomes are deliberately explicit. Nothing here falls back to an
# alphabetical or provider-name guess: a role with no usable folder stays unavailable until an
# administrator supplies one exact override.
class Imap::FolderDiscoveryService
  # Roles map to the RFC 6154 special-use attributes. Gmail's \All is intentionally absent:
  # archiving on Gmail removes the Inbox label rather than moving into All Mail, so All Mail is
  # not an Archive move target.
  ROLE_ATTRIBUTES = {
    'archive' => 'archive',
    'trash' => 'trash',
    'spam' => 'junk',
    'sent' => 'sent'
  }.freeze

  NOSELECT = 'noselect'.freeze

  pattr_initialize [:channel!]

  def perform
    self.class.result_for(folders: list_folders, config: channel.mailbox_sync)
  end

  # Builds a discovery Result from a LIST response. Exposed so that work already holding the
  # per-inbox lease can reuse the same role resolution without taking a second lease.
  def self.result_for(folders:, config:)
    Result.new(folders: normalize(folders), config: config)
  end

  def self.normalize(folders)
    Array(folders).map do |folder|
      {
        name: folder.name,
        delimiter: folder.delim,
        attributes: Array(folder.attr).map { |attribute| attribute.to_s.downcase.delete_prefix('\\') }
      }
    end
  end

  private

  def list_folders
    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      session.command { client.list('', '*') }
    end || []
  end
end
