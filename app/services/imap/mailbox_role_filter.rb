# Applies one mailbox-role EXISTS predicate to a conversation relation before sorting and
# pagination.
class Imap::MailboxRoleFilter
  INCOMING_ROLES = %w[inbox archive trash spam].freeze
  SENT_ROLE = 'sent'.freeze
  MAILBOX_ROLES = (INCOMING_ROLES + [SENT_ROLE]).freeze

  pattr_initialize [:conversations!, :role!, :account!]

  def perform
    return conversations if role.blank? || !account.feature_enabled?('email_mailbox_actions')
    return conversations.none unless MAILBOX_ROLES.include?(role)

    conversations.where(exists_predicate)
  end

  private

  def exists_predicate
    role == SENT_ROLE ? sent_messages.arel.exists : incoming_messages.arel.exists
  end

  def incoming_messages
    Message.unscoped
           .where('messages.conversation_id = conversations.id')
           .where(message_type: Message.message_types[:incoming])
           .where(mailbox_role_condition)
           .select(1)
  end

  # M07 keeps the meaning the deployed Sent view always had, conversation-centric, and clarifies
  # it: a conversation is in Sent when it holds an outgoing message that actually went out as mail.
  # That covers a Chatwoot send and a reply written in another client that Imap::SentInboundImport
  # threaded back in, and neither one waits for Sent-sync to have completed. It reads no message
  # identity at all, which is what makes Inbox membership and Sent membership independent by
  # construction rather than by careful bookkeeping.
  def sent_messages
    Message.unscoped
           .where('messages.conversation_id = conversations.id')
           .where(message_type: Message.message_types[:outgoing], private: false)
           .where.not(source_id: nil)
           .select(1)
  end

  def mailbox_role_condition
    tracked = <<~SQL.squish
      COALESCE(jsonb_array_length(#{normalized_external_source_ids_sql} #> '{imap,locations}'), 0) > 0
      AND COALESCE(#{normalized_external_source_ids_sql} #>> '{imap,sync_state}', '') != 'missing'
    SQL
    return "(#{untracked_identity_condition} OR (#{tracked} AND #{identity_has_role('inbox')}))" if role == 'inbox'
    return "(#{tracked} AND #{archive_identity_condition})" if role == 'archive'

    "(#{tracked} AND #{identity_has_role(role)})"
  end

  def archive_identity_condition
    provider_id = "NULLIF(#{normalized_external_source_ids_sql} #>> '{imap,provider_id}', '')"
    standard_archive = "#{provider_id} IS NULL AND #{identity_has_role('archive')}"
    excluded_roles = %w[inbox trash spam].map { |excluded_role| identity_has_role(excluded_role) }.join(' OR ')
    gmail_archive = "#{provider_id} IS NOT NULL AND NOT (#{excluded_roles})"

    "(#{standard_archive} OR #{gmail_archive})"
  end

  def untracked_identity_condition
    "COALESCE(jsonb_array_length(#{normalized_external_source_ids_sql} #> '{imap,locations}'), 0) = 0"
  end

  def identity_has_role(identity_role)
    identity = { imap: { locations: [{ roles: [identity_role] }] } }.to_json
    ActiveRecord::Base.sanitize_sql_array(["#{normalized_external_source_ids_sql} @> ?::jsonb", identity])
  end

  # Rails' JSON store coder can persist this jsonb attribute as either a JSON object or a JSON
  # string. Extracting the root as text and casting it normalizes both representations.
  def normalized_external_source_ids_sql
    "(messages.external_source_ids #>> '{}')::jsonb"
  end
end
