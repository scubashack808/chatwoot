# Gmail Archive and Restore change only the Inbox label, then confirm the resulting UID identity.
# Trash and Spam keep the standard UID MOVE behavior.
class Imap::MailboxCommand::Gmail < Imap::MailboxCommand::Standard
  LABEL_OPERATIONS = {
    archive: ['-X-GM-LABELS', 'removed the Inbox label'],
    restore: ['+X-GM-LABELS', 'added the Inbox label']
  }.freeze

  private

  def perform(action:, identity:, source:, target:, message_id:)
    return relabel(action: action, identity: identity, source: source, target: target, message_id: message_id) if relabel?(action, identity, source)

    super
  end

  def target_for(action)
    return targets['all'] if action == :archive
    return Imap::MailboxCommand::RESTORE_TARGET if action == :restore

    super
  end

  def stable_search(identity, message_id)
    return ['X-GM-MSGID', identity.provider_id] if identity.provider_id.present?

    super
  end

  def relabel?(action, identity, source)
    return true if action == :archive
    return false unless action == :restore
    return true if Array(source['roles']).include?('archive')

    # A roleless source is All Mail or a user label; UID MOVE out of a label would strip it.
    identity.provider_id.present? && Array(source['roles']).empty?
  end

  def relabel(action:, identity:, source:, target:, message_id:)
    query = stable_search(identity, message_id)
    return conflict('target cannot be confirmed because the message has no stable identifier') if query.nil?

    operation, detail = LABEL_OPERATIONS.fetch(action)
    session.command do |imap|
      before_mutation.call
      imap.uid_store(source['uid'], operation, [Imap::MailboxCommand::INBOX_LABEL])
    end

    confirm_target(
      action: action,
      target: target,
      identity: identity,
      message_id: message_id,
      outcome: { status: :moved, detail: detail, preserve_source: action == :restore }
    )
  end
end
