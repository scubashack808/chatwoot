# TODO: Move this into models jbuilder
# Currently the file there is used only for search endpoint.
# Everywhere else we use conversation builder in partials folder

json.meta do
  json.sender do
    json.partial! 'api/v1/models/contact', formats: [:json], resource: conversation.contact
  end
  json.channel conversation.inbox.try(:channel_type)
  if conversation.assigned_entity.is_a?(AgentBot)
    json.assignee do
      json.partial! 'api/v1/models/agent_bot_slim', formats: [:json], resource: conversation.assigned_entity
    end
    json.assignee_type 'AgentBot'
  elsif conversation.assigned_entity&.account
    json.assignee do
      json.partial! 'api/v1/models/agent', formats: [:json], resource: conversation.assigned_entity
    end
    json.assignee_type 'User'
  end
  if conversation.team.present?
    json.team do
      json.partial! 'api/v1/models/team', formats: [:json], resource: conversation.team
    end
  end
  json.hmac_verified conversation.contact_inbox&.hmac_verified
end

json.id conversation.display_id
if conversation.messages.where(account_id: conversation.account_id).last.blank?
  json.messages []
else
  json.messages [
    conversation.messages.where(account_id: conversation.account_id)
                .includes([{ attachments: [{ file_attachment: [:blob] }] }]).last.try(:push_event_data)
  ]
end

json.account_id conversation.account_id
json.uuid conversation.uuid
json.additional_attributes conversation.additional_attributes
json.agent_last_seen_at conversation.agent_last_seen_at.to_i
json.assignee_last_seen_at conversation.assignee_last_seen_at.to_i
json.can_reply conversation.can_reply?
json.contact_last_seen_at conversation.contact_last_seen_at.to_i
json.custom_attributes conversation.custom_attributes
json.inbox_id conversation.inbox_id
json.labels conversation.cached_label_list_array
json.muted conversation.muted?
json.snoozed_until conversation.snoozed_until
json.status conversation.status
json.created_at conversation.created_at.to_i
json.updated_at conversation.updated_at.to_f
json.timestamp conversation.last_activity_at.to_i
json.first_reply_created_at conversation.first_reply_created_at.to_i
json.unread_count conversation.unread_incoming_messages.count
json.last_non_activity_message conversation.messages.where(account_id: conversation.account_id).non_activity_messages.first.try(:push_event_data)
# A list card marks a conversation replied when the newest public incoming message has a later
# successful agent reply. Only these two anchors are needed to decide that, and filtering on
# message_type keeps activity and template messages out of the answer on both sides.
public_messages = conversation.messages.where(account_id: conversation.account_id, private: false)
newest_first = { created_at: :desc, id: :desc }
incoming_anchor = public_messages.incoming.reorder(newest_first).first
reply_anchor = public_messages.outgoing.where.not(status: :failed).reorder(newest_first).first
json.last_public_incoming_message incoming_anchor && { id: incoming_anchor.id, created_at: incoming_anchor.created_at.to_i }
json.last_agent_reply_message reply_anchor && { id: reply_anchor.id, created_at: reply_anchor.created_at.to_i }
json.last_activity_at conversation.last_activity_at.to_i
json.priority conversation.priority
json.waiting_since conversation.waiting_since.to_i.to_i
sla_applicable = !conversation.respond_to?(:sla_applicable?) || conversation.sla_applicable?
json.sla_policy_id sla_applicable ? conversation.sla_policy_id : nil

if Current.account.feature_enabled?('email_mailbox_actions')
  conversations = @conversations || [conversation]
  mailbox_data = @conversation_mailbox_data ||= Imap::ConversationMailboxData.new(
    conversations: conversations,
    user: Current.user,
    account_user: Current.account_user
  ).to_h
  conversation_mailbox_data = mailbox_data[conversation.id]
  if conversation_mailbox_data
    json.mailbox_state conversation_mailbox_data[:mailbox_state]
    json.mailbox_operation conversation_mailbox_data[:mailbox_operation]
  end
end

json.partial! 'enterprise/api/v1/conversations/partials/conversation', conversation: conversation if ChatwootApp.enterprise?
