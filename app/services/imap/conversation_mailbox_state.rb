# Derives conversation mailbox placement directly from incoming message identities and the latest
# durable operation. It never writes a conversation-level projection.
class Imap::ConversationMailboxState
  MAILBOX_ROLES = %w[inbox archive trash spam].freeze
  PROVIDER_ABSENT_STATE = 'missing'.freeze

  # The one place that decides whether mailbox state may be published for a conversation, so the
  # three publication paths cannot drift apart: the conversation list payload, the mailbox
  # operations controller, and the realtime operation event.
  #
  # Returns the state, or nil when publishing it would offer an action that cannot succeed. Callers
  # must OMIT the key on nil rather than send null, because the dashboard tests for it with
  # hasOwnProperty and a null still counts as data.
  #
  # Imap::ConversationMailboxData deliberately does not call this. It answers the same question for
  # a whole page with two queries instead of two per conversation.
  def self.publishable(conversation:)
    channel = conversation.inbox.channel
    return nil unless channel.respond_to?(:mailbox_sync) && channel.mailbox_sync.provider_mutation_allowed?

    state = new(conversation: conversation)
    state.actionable? ? state : nil
  end

  def initialize(
    conversation:,
    incoming_messages: conversation.messages.incoming.order(:id),
    latest_operation: EmailMailboxOperation.where(conversation_id: conversation.id).order(created_at: :desc, id: :desc).first
  )
    @conversation = conversation
    @incoming_messages = incoming_messages
    @latest_operation = latest_operation
  end

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

  # Whether a mailbox action could address this conversation at all.
  #
  # #state is the wrong thing to ask, because every value it can return for a conversation with no
  # tracked identity still reads as actionable to the dashboard. Mail that predates identity
  # capture reports 'mixed', since untracked_count is positive while roles is empty; mail that sits
  # alongside tracked inbox mail reports 'inbox'. Both are right for telling a reader where the
  # conversation is, and both make getMailboxActions offer Archive, Spam and Trash, because
  # mailboxStateIncludesRole treats a positive untracked_count as inbox membership.
  #
  # There is nothing on the server to move, so the request would be accepted and then fail on
  # identity_missing. Callers deciding whether to publish ask this, not #state.
  def actionable?
    tracked_identities.any?
  end

  private

  attr_reader :conversation, :incoming_messages, :latest_operation

  def incoming_identities
    @incoming_identities ||= incoming_messages.map(&:imap_identity)
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
    latest_operation&.count_results('conflict').to_i
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
