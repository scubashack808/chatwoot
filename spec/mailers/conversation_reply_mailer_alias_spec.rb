require 'rails_helper'

# Row 09 behaviours A03 (default reply From to the receiving alias), A04 (an agent may choose
# another channel-owned From) and A05 (Reply-To matches the selected From identity).
#
# Both send paths are exercised on purpose: the legacy mailer helper path and the
# reply_mailer_migration builder path. The deployed fork had to patch both for the same reason.
RSpec.describe ConversationReplyMailer do
  let(:account) { create(:account) }
  let(:agent) { create(:user, email: 'agent@example.com', account: account) }
  let(:channel) do
    create(:channel_email, account: account, email: 'care@example.com',
                           aliases: ['nonprofit@example.com'],
                           smtp_enabled: true, smtp_address: 'smtp.example.com',
                           imap_enabled: true, imap_address: 'imap.example.com')
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, email: 'customer@example.com') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:class_instance) { described_class.new }

  before do
    allow(described_class).to receive(:new).and_return(class_instance)
    allow(class_instance).to receive(:smtp_config_set_or_development?).and_return(true)
  end

  def incoming_email(to:)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, content_type: :incoming_email,
                     content_attributes: { email: { to: to, cc: [], bcc: [] } })
  end

  def outgoing_reply(content_attributes = {})
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                     message_type: :outgoing, content: 'Thanks for writing in',
                     content_attributes: content_attributes)
  end

  # .message renders the real mail through the real mailer without opening an SMTP connection.
  # These channels have smtp_enabled on purpose, because that is the branch that resolves the
  # From identity, and delivering would try to reach smtp.example.com.
  def rendered_reply(content_attributes = {})
    described_class.email_reply(outgoing_reply(content_attributes)).message
  end

  shared_examples 'alias-aware outbound identity' do
    it 'sends from the primary when the inbound mail arrived at the primary' do
      incoming_email(to: ['care@example.com'])

      mail = rendered_reply

      expect(mail.from).to eq(['care@example.com'])
      expect(mail.reply_to).to eq(['care@example.com'])
    end

    it 'sends from the alias the inbound mail arrived at' do
      incoming_email(to: ['nonprofit@example.com'])

      mail = rendered_reply

      expect(mail.from).to eq(['nonprofit@example.com'])
    end

    it 'aligns Reply-To with the alias From identity' do
      incoming_email(to: ['nonprofit@example.com'])

      mail = rendered_reply

      expect(mail.reply_to).to eq(mail.from)
      expect(mail.reply_to).to eq(['nonprofit@example.com'])
    end

    it 'honours an agent override that the channel owns, and aligns Reply-To with it' do
      incoming_email(to: ['nonprofit@example.com'])

      mail = rendered_reply(from_email: 'care@example.com')

      expect(mail.from).to eq(['care@example.com'])
      expect(mail.reply_to).to eq(['care@example.com'])
    end

    it 'never emits an address the channel does not own' do
      incoming_email(to: ['nonprofit@example.com'])

      mail = rendered_reply(from_email: 'attacker@evil.com')

      expect(mail.from).to eq(['nonprofit@example.com'])
      expect(mail.reply_to).to eq(['nonprofit@example.com'])
    end

    it 'follows the latest inbound message rather than the first' do
      incoming_email(to: ['nonprofit@example.com'])
      incoming_email(to: ['care@example.com'])

      mail = rendered_reply

      expect(mail.from).to eq(['care@example.com'])
      expect(mail.reply_to).to eq(['care@example.com'])
    end
  end

  context 'with the legacy mailer path' do
    it_behaves_like 'alias-aware outbound identity'
  end

  context 'with the reply_mailer_migration builder path' do
    before { account.enable_features!('reply_mailer_migration') }

    it_behaves_like 'alias-aware outbound identity'
  end
end
