# Derives conversation mailbox placement directly from incoming message identities and the latest
# durable operation. It never writes a conversation-level projection.
class Imap::ConversationMailboxState
  MAILBOX_ROLES = %w[inbox archive trash spam].freeze
  PROVIDER_ABSENT_STATE = 'missing'.freeze

  pattr_initialize [:conversation!]

  def to_h
    {
      state: state,
      roles: roles,
      tracked_count: tracked_identities.length,
      untracked_count: untracked_count,
      missing_count: missing_count,
      conflict_count: conflict_count
    }
  end

  private

  def incoming_identities
    @incoming_identities ||= conversation.messages.incoming.order(:id).map(&:imap_identity)
  end

  def tracked_identities
    @tracked_identities ||= incoming_identities.compact.reject { |identity| identity.sync_state == PROVIDER_ABSENT_STATE }
  end

  def untracked_count
    incoming_identities.count(&:nil?)
  end

  def missing_count
    incoming_identities.compact.count { |identity| identity.sync_state == PROVIDER_ABSENT_STATE }
  end

  def roles
    @roles ||= tracked_identities
               .flat_map { |identity| logical_roles(identity) }
               .uniq
               .sort_by { |role| MAILBOX_ROLES.index(role) }
  end

  def logical_roles(identity)
    stored_roles = identity.locations.flat_map { |location| Array(location['roles']) }.intersection(MAILBOX_ROLES)
    return stored_roles if identity.provider_id.blank?

    [(%w[trash spam inbox archive] & stored_roles).first || 'archive']
  end

  def conflict_count
    latest = EmailMailboxOperation.where(conversation_id: conversation.id).order(created_at: :desc).first
    latest&.count_results('conflict').to_i
  end

  def state
    return 'mixed' if mixed?
    return roles.first if roles.one?
    return 'inbox' if untracked_count.positive?

    'mixed'
  end

  def mixed?
    conflict_count.positive? ||
      missing_count.positive? ||
      roles.many? ||
      (untracked_count.positive? && roles.exclude?('inbox'))
  end
end
