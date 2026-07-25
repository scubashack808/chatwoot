# Imap::MailboxCommand executes exactly one mailbox action against exactly one message.
#
# It is deliberately small and dialect-aware rather than a general mailbox framework: the only
# operations that exist here are the four the product needs, and the only dialects are standard
# IMAP and Gmail.
#
# Gmail is selected by the advertised X-GM-EXT-1 capability, never by Chatwoot's provider field,
# which is blank on every live channel including the Gmail-hosted one.
#
# Every command refuses rather than guesses:
#   - a mailbox whose UIDVALIDITY no longer matches the stored identity is a different generation,
#     so the stored UID means nothing and the command stops;
#   - a UID that has vanished means another client moved it first, which is a conflict, not a
#     failure to retry blindly;
#   - a role with no configured folder is a conflict, never an alphabetical or provider-name guess.
#
# All current production servers advertise MOVE, so there is no COPY/STORE/EXPUNGE fallback. A
# server without MOVE stays observe-only rather than gaining a mail-loss path.
class Imap::MailboxCommand
  RESTORE_TARGET = Imap::MailboxSyncConfig::RESTORE_TARGET
  GMAIL_CAPABILITY = 'X-GM-EXT-1'.freeze
  INBOX_LABEL = '\\Inbox'.freeze

  Result = Struct.new(:status, :target_mailbox, :target_uidvalidity, :target_uid, :detail, keyword_init: true)

  def self.dialect_for(client)
    client.capabilities.include?(GMAIL_CAPABILITY) ? Gmail : Standard
  rescue StandardError
    Standard
  end

  # Standard IMAP: every action is a UID MOVE to an exact, configured mailbox.
  class Standard
    def initialize(session:, client:, targets:)
      @session = session
      @client = client
      @targets = targets
    end

    def call(action:, identity:, message_id: nil)
      target = target_for(action)
      return conflict("#{action} target is not configured for this inbox") if target.blank?
      return Imap::MailboxCommand::Result.new(status: :already_in_target, target_mailbox: target) if identity.mailbox == target

      guard = verify_source(identity)
      return guard if guard

      perform(action: action, identity: identity, target: target, message_id: message_id)
    end

    private

    attr_reader :session, :client, :targets

    def perform(action:, identity:, target:, message_id:)
      move(identity: identity, target: target, message_id: message_id)
    end

    def target_for(action)
      return Imap::MailboxCommand::RESTORE_TARGET if action.to_sym == :restore

      targets[action.to_s]
    end

    # Selects the mailbox the identity actually names and proves the generation still matches.
    def verify_source(identity)
      session.command { client.select(identity.mailbox) }
      current = Array(client.responses('UIDVALIDITY')).last

      if current.to_i != identity.uidvalidity.to_i
        return conflict("mailbox uidvalidity changed from #{identity.uidvalidity} to #{current}, stored uid is stale")
      end

      return conflict('uid is no longer present, another client moved it first') if uid_missing?(identity)

      nil
    end

    def uid_missing?(identity)
      Array(session.command { client.uid_search(['UID', identity.uid]) }).exclude?(identity.uid)
    end

    def move(identity:, target:, message_id:)
      client.clear_responses('COPYUID')
      session.command { client.uid_move(identity.uid, target) }

      copyuid = Array(client.responses('COPYUID')).last
      return moved(target, copyuid.uidvalidity, copyuid.assigned_uids.first) if copyuid.present?

      confirm_without_copyuid(target: target, message_id: message_id)
    end

    # A server may advertise UIDPLUS and still omit the optional COPYUID mapping. One unique match
    # on a stable identifier confirms the target; anything else is a conflict.
    def confirm_without_copyuid(target:, message_id:)
      return conflict('server returned no COPYUID and the message has no stable identifier') if message_id.blank?

      session.command { client.select(target) }
      uidvalidity = Array(client.responses('UIDVALIDITY')).last
      hits = Array(session.command { client.uid_search(['HEADER', 'MESSAGE-ID', message_id]) })

      return conflict("target could not be confirmed uniquely, #{hits.length} candidates") unless hits.one?

      moved(target, uidvalidity, hits.first)
    end

    def moved(mailbox, uidvalidity, uid)
      Imap::MailboxCommand::Result.new(status: :moved, target_mailbox: mailbox,
                                       target_uidvalidity: uidvalidity, target_uid: uid)
    end

    def conflict(detail)
      Imap::MailboxCommand::Result.new(status: :conflict, detail: detail)
    end
  end

  # Gmail: archiving removes the Inbox label rather than moving into All Mail, and restoring puts
  # the label back. Trash and Spam are still ordinary moves into real folders.
  class Gmail < Standard
    private

    def perform(action:, identity:, target:, message_id:)
      case action.to_sym
      when :archive then relabel(identity, '-X-GM-LABELS', 'removed the Inbox label')
      when :restore then relabel(identity, '+X-GM-LABELS', 'added the Inbox label')
      else super
      end
    end

    def target_for(action)
      # Archive is not a folder on Gmail, and restore is a label change, so neither has a target
      # mailbox to look up. A non-blank sentinel keeps the caller's "is it configured" check happy.
      return :label if %i[archive restore].include?(action.to_sym)

      super
    end

    def relabel(identity, operation, detail)
      session.command { client.uid_store(identity.uid, operation, [Imap::MailboxCommand::INBOX_LABEL]) }

      Imap::MailboxCommand::Result.new(status: :moved, detail: detail)
    end
  end
end
