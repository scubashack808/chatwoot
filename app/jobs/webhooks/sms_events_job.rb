class Webhooks::SmsEventsJob < ApplicationJob
  queue_as :default

  SUPPORTED_EVENTS = %w[message-received message-delivered message-failed].freeze

  def perform(params = {})
    return unless SUPPORTED_EVENTS.include?(params[:type])

    # Outbound status events address the customer in `to`; the sending channel is `message.from`.
    phone_number = delivery_event?(params) ? params[:message][:from] : params[:to]
    channel = Channel::Sms.find_by(phone_number: phone_number)
    return unless channel

    process_event_params(channel, params)
  end

  private

  def process_event_params(channel, params)
    if delivery_event?(params)
      Sms::DeliveryStatusService.new(inbox: channel.inbox, params: params.with_indifferent_access).perform
    else
      Sms::IncomingMessageService.new(inbox: channel.inbox, params: params[:message].with_indifferent_access).perform
    end
  end

  def delivery_event?(params)
    params[:type] == 'message-delivered' || params[:type] == 'message-failed'
  end
end
