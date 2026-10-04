class Instagram::SendOnInstagramService < Instagram::BaseSendService
  private

  def channel_class
    Channel::Instagram
  end

  # Deliver a message with the given payload.
  # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api
  def send_message(message_content)
    access_token = channel.access_token
    query = { access_token: access_token }
    instagram_id = channel.instagram_id.presence || 'me'

    begin
      response = HTTParty.post(
        "https://graph.instagram.com/#{GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v22.0')}/#{instagram_id}/messages",
        body: message_content,
        query: query
      )
    rescue Errno::ECONNREFUSED => e
      # An earlier attachment may already have been accepted; do not enable replay.
      raise if message.attachments.present?

      Messages::StatusUpdateService.new(message, 'failed', 'Instagram connection refused before sending. Please retry.').perform
      handle_error(e)
      return
    end

    process_response(response, message_content)
  end

  def merge_human_agent_tag(params)
    global_config = GlobalConfig.get('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')

    return params unless global_config['ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']

    params[:messaging_type] = 'MESSAGE_TAG'
    params[:tag] = 'HUMAN_AGENT'
    params
  end
end
