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

module RcBridgePayload
  module_function

  def value(attributes, key)
    attributes[key.to_s] || attributes[key.to_sym]
  end

  def numeric_identifier?(value)
    value.to_s.match?(/\A\d+\z/)
  end

  def timestamp(raw_epoch)
    epoch = Integer(raw_epoch, exception: false)
    return unless epoch&.between?(
      RcBridgeMessageTimestamp::MINIMUM_EPOCH,
      Time.now.to_i + RcBridgeMessageTimestamp::MAXIMUM_FUTURE_SECONDS
    )

    Time.zone.at(epoch)
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
    return values unless rc_bridge_payload?(attributes)

    canonical_time = RcBridgePayload.timestamp(RcBridgePayload.value(attributes, :rc_created_at_epoch))
    return values unless canonical_time

    values.merge(created_at: canonical_time, updated_at: canonical_time)
  end

  def rc_bridge_payload?(attributes)
    inbox = @conversation.inbox
    RcBridgeScope.inbox?(inbox) &&
      inbox.channel_type == 'Channel::Api' &&
      SURFACES.include?(RcBridgePayload.value(attributes, :rc_source_surface).to_s) &&
      RcBridgePayload.numeric_identifier?(RcBridgePayload.value(attributes, :rc_message_id))
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
    return values unless rc_bridge_payload?(attributes)

    canonical_time = RcBridgePayload.timestamp(RcBridgePayload.value(attributes, :rc_initial_created_at_epoch))
    return values unless canonical_time

    values.merge(
      created_at: canonical_time,
      updated_at: canonical_time,
      last_activity_at: canonical_time
    )
  end

  def rc_bridge_payload?(attributes)
    RcBridgeScope.inbox?(@contact_inbox.inbox) &&
      RcBridgePayload.numeric_identifier?(RcBridgePayload.value(attributes, :rc_conversation_id))
  end
end

module RcBridgeDerivedTimestamps
  def rc_bridge_reconcile_derived_timestamps
    return unless rc_bridge_source_message?

    earliest, latest = rc_bridge_conversation_range
    return unless earliest && latest

    rc_bridge_update_conversation(earliest, latest)
    rc_bridge_update_contact
  end

  private

  def rc_bridge_source_message?
    attributes = content_attributes || {}
    surface = RcBridgePayload.value(attributes, :rc_source_surface)
    RcBridgeScope.message?(self) && RcBridgeMessageTimestamp::SURFACES.include?(surface.to_s)
  end

  def rc_bridge_user_message_types
    [
      Message.message_types.fetch('incoming'),
      Message.message_types.fetch('outgoing')
    ]
  end

  def rc_bridge_conversation_range
    messages = Message.where(
      conversation_id: conversation_id,
      message_type: rc_bridge_user_message_types
    )
    [messages.minimum(:created_at), messages.maximum(:created_at)]
  end

  def rc_bridge_update_conversation(earliest, latest)
    # This callback is itself reconciling denormalized timestamps after commit.
    # Running validations or callbacks here would recurse and replace the imported
    # historical time with Chatwoot's normal wall-clock value.
    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_columns(
      created_at: earliest,
      updated_at: latest,
      last_activity_at: latest
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def rc_bridge_update_contact
    contact_latest = Message.joins(:conversation)
                            .where(conversations: { contact_id: conversation.contact_id })
                            .where(message_type: rc_bridge_user_message_types)
                            .maximum('messages.created_at')
    return unless contact_latest

    # See rc_bridge_update_conversation: callbacks must not rewrite the
    # historical timestamp that this reconciliation just established.
    # rubocop:disable Rails/SkipsModelValidations
    conversation.contact.update_column(:last_activity_at, contact_latest)
    # rubocop:enable Rails/SkipsModelValidations
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
  RETRY_ERROR = 'Automatic retry is disabled for RingCentral messages. Compose a new message instead.'

  def retry
    return super unless RcBridgeScope.inbox?(@conversation.inbox)
    return super unless message.failed?

    render json: { error: RETRY_ERROR }, status: :unprocessable_content
  end
end

Rails.application.config.to_prepare do
  # ActiveJob otherwise writes complete webhook and ActionCable payloads into
  # Sidekiq logs. Delivery does not require those arguments to be logged.
  WebhookJob.log_arguments = false if WebhookJob.respond_to?(:log_arguments=)
  ActionCableBroadcastJob.log_arguments = false if ActionCableBroadcastJob.respond_to?(:log_arguments=)

  Messages::MessageBuilder.prepend(RcBridgeMessageTimestamp) unless Messages::MessageBuilder <= RcBridgeMessageTimestamp
  SearchService.prepend(RcBridgeFullHistorySearch) unless SearchService <= RcBridgeFullHistorySearch
  ConversationBuilder.prepend(RcBridgeConversationTimestamp) unless ConversationBuilder <= RcBridgeConversationTimestamp
  Messages::StatusUpdateService.prepend(RcBridgeTerminalStatus) unless Messages::StatusUpdateService <= RcBridgeTerminalStatus
  unless Api::V1::Accounts::Conversations::MessagesController <= RcBridgeMessageRetryGuard
    Api::V1::Accounts::Conversations::MessagesController.prepend(RcBridgeMessageRetryGuard)
  end
  unless Message <= RcBridgeDerivedTimestamps
    Message.include(RcBridgeDerivedTimestamps)
    # Rails runs after-commit callbacks in reverse declaration order in this
    # build. Prepending makes this reconciliation run after Chatwoot's own
    # NOW-based contact callback.
    Message.after_create_commit :rc_bridge_reconcile_derived_timestamps, prepend: true
  end
end
