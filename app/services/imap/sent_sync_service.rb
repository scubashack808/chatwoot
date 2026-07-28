# Synchronises one inbox's Sent folder, in both directions, on one connection.
#
# Plan section 7, in full, is what this implements:
#
#   "Gmail is selected by the advertised X-GM-EXT-1 capability, not the Chatwoot provider field.
#    Google documents that SMTP already copies sent messages into Gmail Sent, so provider-managed
#    mode searches and attaches that copy and never APPENDs it.
#    Generic append mode searches first, APPENDs only when configured, captures APPENDUID, and
#    retries idempotently. An SMTP success remains delivery success; Sent synchronization has its
#    own visible state and retry."
#
# Two decisions in here are worth a reviewer's attention:
#
#   1. The advertised capability, not the configured mode, has the final say on APPEND. A server
#      advertising X-GM-EXT-1 already holds the copy its own SMTP saved, so appending would create
#      exactly the duplicate this row exists to prevent. An inbox configured for append against
#      such a server is reported as running provider-managed, rather than silently doing what the
#      configuration says and duplicating mail.
#   2. observe mode runs, but never appends. Searching Sent and recording where a message already
#      lives mutates nothing on the server, which is precisely what observe permits; APPEND writes
#      to the mailbox, which is precisely what it forbids.
#
# It runs from the existing */1 fan-out under the same per-inbox Imap::Lease as ingestion, so it
# adds no scheduler and no second connection lane. Lease contention raises out of here and the job
# defers to the next cycle.
class Imap::SentSyncService
  PROVIDER_MANAGED = 'provider_managed'.freeze
  APPEND = 'append'.freeze
  DISABLED = 'disabled'.freeze
  SENT_ROLE = 'sent'.freeze

  def initialize(channel:, interval: 1)
    @channel = channel
    @interval = interval
  end

  # Dark twice over, the same as every other mailbox path in this stack: the account feature flag
  # and the per-inbox mode. The flag is checked FIRST, matching
  # Imap::MailboxReconciliationService#blocking_reason, so an inbox that is both un-flagged and off
  # reports the outer reason rather than the inner one. Both this and the enqueue gate in
  # Inboxes::FetchImapEmailInboxesJob are required: the enqueue gate keeps a dark feature free, and
  # this one holds when the service is called directly.
  def perform
    return skipped('feature_disabled') unless channel.account.feature_enabled?('email_mailbox_actions')
    return skipped('mailbox_sync_off') if config.off?
    return skipped('sent_sync_disabled') if config.sent_mode == DISABLED

    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      run(client, session)
    end
  end

  private

  attr_reader :channel, :interval

  def config
    @config ||= channel.mailbox_sync
  end

  def run(client, session)
    gmail = gmail_dialect?(client, session)
    role = resolve_sent_role(client, session)
    return skipped('sent_folder_unavailable', gmail: gmail, detail: role.status) unless role.available?

    mailbox = Imap::SentMailbox.new(
      client: client, session: session, mailbox: role.selected, append_allowed: append_allowed?(gmail)
    ).examine!

    completed(mailbox, gmail)
  end

  # The exact folder the server marks \Sent, or the exact administrator override, re-validated
  # against this LIST. Zero or multiple candidates leave Sent sync unavailable for this inbox
  # rather than falling back to a name.
  def resolve_sent_role(client, session)
    folders = session.command { client.list('', '*') }
    Imap::FolderDiscoveryService.result_for(folders: folders, config: config).for_role(SENT_ROLE)
  end

  # CAPABILITY goes through session.command like every other provider command, so it renews the
  # lease first and runs inside the command timeout. It is read once and handed to the dialect
  # selector rather than letting that re-fetch it, because this is the command that decides
  # whether APPEND is allowed at all: it is the last one that should be able to reach the server
  # after the lease was lost, or to hang unbounded.
  def gmail_dialect?(client, session)
    capabilities = session.command(&:capabilities)
    Imap::MailboxCommand.dialect_for(client, capabilities: capabilities) == Imap::MailboxCommand::Gmail
  end

  def append_allowed?(gmail)
    config.sent_mode == APPEND && config.provider_mutation_allowed? && !gmail
  end

  def effective_sent_mode(mailbox)
    mailbox.append_allowed? ? APPEND : PROVIDER_MANAGED
  end

  def completed(mailbox, gmail)
    {
      status: 'completed', reason: nil, inbox_id: channel.inbox.id, mailbox: mailbox.mailbox,
      gmail: gmail, sent_mode: config.sent_mode, effective_sent_mode: effective_sent_mode(mailbox),
      outbound: Imap::SentOutboundSync.new(channel: channel, sent_mailbox: mailbox).perform,
      inbound: Imap::SentInboundImport.new(channel: channel, sent_mailbox: mailbox, interval: interval).perform
    }
  end

  def skipped(reason, gmail: nil, detail: nil)
    {
      status: 'skipped', reason: reason, detail: detail, inbox_id: channel.inbox.id,
      mailbox: nil, gmail: gmail, sent_mode: config.sent_mode, effective_sent_mode: nil,
      outbound: {}, inbound: {}
    }
  end
end
