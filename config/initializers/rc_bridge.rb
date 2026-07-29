# frozen_string_literal: true

# Production-safe compatibility layer for the Extended Horizons RingCentral
# API inbox.
#
# Scope is fail-closed. Both RC_BRIDGE_ACCOUNT_IDS and RC_BRIDGE_INBOX_IDS must
# name the current record before this initializer changes Chatwoot behavior.
# The fake clone's private-network webhook exception is deliberately not in
# this file and must never be copied into the production image.
module RcBridgeScope
  module_function

  def configured_ids(name)
    ENV.fetch(name, '').split(',').filter_map do |value|
      Integer(value.strip, exception: false)
    end.to_set
  end

  def account_id?(account_id)
    configured_ids('RC_BRIDGE_ACCOUNT_IDS').include?(account_id.to_i)
  end

  def inbox?(inbox)
    return false unless inbox

    account_id?(inbox.account_id) &&
      configured_ids('RC_BRIDGE_INBOX_IDS').include?(inbox.id.to_i)
  end

  def message?(message)
    inbox?(message&.inbox)
  end
end

module RcBridgeMessageTimestamp
  MINIMUM_EPOCH = 946_684_800 # 2000-01-01 UTC
  MAXIMUM_FUTURE_SECONDS = 300
  SURFACES = %w[customer_sms ringcentral_app].freeze

  private

  def message_params
    values = super
    attributes = values[:content_attributes] || {}
    surface = attributes['rc_source_surface'] || attributes[:rc_source_surface]
    rc_message_id = attributes['rc_message_id'] || attributes[:rc_message_id]
    raw_epoch = attributes['rc_created_at_epoch'] || attributes[:rc_created_at_epoch]

    return values unless RcBridgeScope.inbox?(@conversation.inbox)
    return values unless @conversation.inbox.channel_type == 'Channel::Api'
    return values unless SURFACES.include?(surface.to_s)
    return values unless rc_message_id.to_s.match?(/\A\d+\z/)

    epoch = Integer(raw_epoch, exception: false)
    return values unless epoch
    return values unless epoch.between?(MINIMUM_EPOCH, Time.now.to_i + MAXIMUM_FUTURE_SECONDS)

    canonical_time = Time.zone.at(epoch)
    values.merge(created_at: canonical_time, updated_at: canonical_time)
  end
end

module RcBridgeFullHistorySearch
  private

  def message_base_query
    return super unless RcBridgeScope.account_id?(current_account.id)

    query = current_account.messages
    query = query.where(inbox_id: accessable_inbox_ids) unless should_skip_inbox_filtering?
    query
  end

  def cap_since_time(since_param)
    return super unless RcBridgeScope.account_id?(current_account.id)

    Time.zone.at(since_param.to_i)
  end
end

module RcBridgeConversationTimestamp
  private

  def conversation_params
    values = super
    attributes = values[:custom_attributes] || {}
    rc_conversation_id = attributes['rc_conversation_id'] || attributes[:rc_conversation_id]
    raw_epoch = attributes['rc_initial_created_at_epoch'] || attributes[:rc_initial_created_at_epoch]
    epoch = Integer(raw_epoch, exception: false)

    return values unless RcBridgeScope.inbox?(@contact_inbox.inbox)
    return values unless rc_conversation_id.to_s.match?(/\A\d+\z/)
    return values unless epoch
    return values unless epoch.between?(
      RcBridgeMessageTimestamp::MINIMUM_EPOCH,
      Time.now.to_i + RcBridgeMessageTimestamp::MAXIMUM_FUTURE_SECONDS
    )

    canonical_time = Time.zone.at(epoch)
    values.merge(
      created_at: canonical_time,
      updated_at: canonical_time,
      last_activity_at: canonical_time
    )
  end
end

module RcBridgeDerivedTimestamps
  def rc_bridge_reconcile_derived_timestamps
    return unless RcBridgeScope.message?(self)

    attributes = content_attributes || {}
    surface = attributes['rc_source_surface'] || attributes[:rc_source_surface]
    return unless RcBridgeMessageTimestamp::SURFACES.include?(surface.to_s)

    user_message_types = [
      Message.message_types.fetch('incoming'),
      Message.message_types.fetch('outgoing')
    ]
    scoped_messages = Message.where(
      conversation_id: conversation_id,
      message_type: user_message_types
    )
    earliest = scoped_messages.minimum(:created_at)
    latest = scoped_messages.maximum(:created_at)
    return unless earliest && latest

    conversation.update_columns(
      created_at: earliest,
      updated_at: latest,
      last_activity_at: latest
    )

    contact_latest = Message.joins(:conversation)
                            .where(conversations: { contact_id: conversation.contact_id })
                            .where(message_type: user_message_types)
                            .maximum('messages.created_at')
    conversation.contact.update_column(:last_activity_at, contact_latest) if contact_latest
  end
end

module RcBridgeTerminalStatus
  private

  def update_message_status
    return super unless RcBridgeScope.message?(message)

    # Stage the retry marker before Chatwoot's original update! call. Active Record
    # then persists status, external_error, and content_attributes together, so the
    # after_update_commit broadcast contains the marker on its first realtime event.
    attributes = (message.content_attributes || {}).deep_dup
    if status == 'failed'
      attributes['rc_retry_disabled'] = true
    else
      attributes.delete('rc_retry_disabled')
    end
    message.content_attributes = attributes
    super
  end
end

module RcBridgeMessageRetryGuard
  RETRY_ERROR = 'Automatic retry is disabled for RingCentral messages. Compose a new message instead.'.freeze

  def retry
    return super unless RcBridgeScope.inbox?(@conversation.inbox)
    return super unless message.failed?

    render json: { error: RETRY_ERROR }, status: :unprocessable_entity
  end
end

Rails.application.config.to_prepare do
  # ActiveJob otherwise writes complete webhook and ActionCable payloads into
  # Sidekiq logs. Delivery does not require those arguments to be logged.
  WebhookJob.log_arguments = false if WebhookJob.respond_to?(:log_arguments=)
  ActionCableBroadcastJob.log_arguments = false if ActionCableBroadcastJob.respond_to?(:log_arguments=)

  unless Messages::MessageBuilder.ancestors.include?(RcBridgeMessageTimestamp)
    Messages::MessageBuilder.prepend(RcBridgeMessageTimestamp)
  end
  unless SearchService.ancestors.include?(RcBridgeFullHistorySearch)
    SearchService.prepend(RcBridgeFullHistorySearch)
  end
  unless ConversationBuilder.ancestors.include?(RcBridgeConversationTimestamp)
    ConversationBuilder.prepend(RcBridgeConversationTimestamp)
  end
  unless Messages::StatusUpdateService.ancestors.include?(RcBridgeTerminalStatus)
    Messages::StatusUpdateService.prepend(RcBridgeTerminalStatus)
  end
  unless Api::V1::Accounts::Conversations::MessagesController.ancestors.include?(RcBridgeMessageRetryGuard)
    Api::V1::Accounts::Conversations::MessagesController.prepend(RcBridgeMessageRetryGuard)
  end
  unless Message.ancestors.include?(RcBridgeDerivedTimestamps)
    Message.include(RcBridgeDerivedTimestamps)
    # Rails runs after-commit callbacks in reverse declaration order in this
    # build. Prepending makes this reconciliation run after Chatwoot's own
    # NOW-based contact callback.
    Message.after_create_commit :rc_bridge_reconcile_derived_timestamps, prepend: true
  end
end
