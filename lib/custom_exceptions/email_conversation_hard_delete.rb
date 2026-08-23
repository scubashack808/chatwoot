class CustomExceptions::EmailConversationHardDelete < CustomExceptions::Base
  def initialize(_data = {})
    super({})
  end

  def message
    I18n.t('errors.conversations.email_hard_delete')
  end

  def http_status
    422
  end
end
