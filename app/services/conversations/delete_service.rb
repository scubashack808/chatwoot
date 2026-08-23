class Conversations::DeleteService
  pattr_initialize [:conversation!, :user, :ip]

  def perform
    raise CustomExceptions::EmailConversationHardDelete if conversation.inbox.email?

    ::DeleteObjectJob.perform_later(conversation, user, ip)
  end
end
