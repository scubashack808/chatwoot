# Imap::MailboxTargets resolves the exact server mailbox each mailbox action would use, and reports
# which actions have no usable target.
#
# It exists so the executor and the activation check cannot disagree about what "archive works
# here" means. Gmail archive does not use the archive role at all: it strips the Inbox label and
# resolves through the \All mailbox, so a check written against targets['archive'] reports every
# Gmail inbox as unable to archive while the executor archives it perfectly well. Keeping one
# resolution and one dialect rule in one place is the only way that stays true.
class Imap::MailboxTargets
  ACTIONS = %w[archive trash spam].freeze
  ALL_MAIL = 'all'.freeze

  # Opens one connection and reads only CAPABILITY and LIST. Nothing is selected and nothing is
  # mutated.
  def self.for_channel(channel)
    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      capabilities = session.command(&:capabilities)
      listing = session.command { |imap| imap.list('', '*') } || []

      new(
        listing: listing,
        config: channel.mailbox_sync,
        gmail: Imap::MailboxCommand.dialect_for(client, capabilities: capabilities) == Imap::MailboxCommand::Gmail
      )
    end
  end

  def initialize(listing:, config:, gmail: false)
    @listing = listing
    @config = config
    @gmail = gmail
  end

  # The same hash Imap::MailboxCommand receives. Deliberately dialect independent, because the
  # dialect itself decides which key it reads.
  def to_h
    @to_h ||= begin
      resolved = ACTIONS.index_with { |role| discovery.for_role(role).selected }
      resolved[ALL_MAIL] = all_mail.first[:name] if all_mail.one?
      resolved
    end
  end

  # Mirrors Imap::MailboxCommand::Standard#target_for and its Gmail override.
  def target_for(action)
    return to_h[ALL_MAIL] if gmail && action.to_s == 'archive'

    to_h[action.to_s]
  end

  def unavailable
    ACTIONS.reject { |action| target_for(action).present? }
  end

  def available?
    unavailable.empty?
  end

  private

  attr_reader :listing, :config, :gmail

  def discovery
    @discovery ||= Imap::FolderDiscoveryService.result_for(folders: listing, config: config)
  end

  def all_mail
    discovery.folders.select do |folder|
      folder[:attributes].include?(ALL_MAIL) && folder[:attributes].exclude?(Imap::FolderDiscoveryService::NOSELECT)
    end
  end
end
