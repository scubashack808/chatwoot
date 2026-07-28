class Email::ReplyToBuilder < Email::BaseBuilder
  pattr_initialize [:inbox!, :message!]

  def build
    reply_to = if inbox.email?
                 # A05: Reply-To follows the same identity the From header resolved to, so a
                 # customer who hits Reply reaches the address they originally wrote to.
                 channel.outbound_address_for(conversation, message: message)
               elsif inbound_email_enabled?
                 "reply+#{conversation.uuid}@#{account.inbound_email_domain}"
               else
                 account_support_email
               end

    sender_name(reply_to)
  end

  private

  def inbound_email_enabled?
    account.feature_enabled?('inbound_emails') && account.inbound_email_domain.present?
  end
end
