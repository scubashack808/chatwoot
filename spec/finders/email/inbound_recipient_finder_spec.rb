require 'rails_helper'

# Row 09 behaviour A02: remember which verified address received each inbound message,
# MESSAGE-scoped. The old fork stored this on the conversation, where it went stale as soon as
# later mail arrived at a different address (execution plan, red-team finding 2).
RSpec.describe Email::InboundRecipientFinder do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_email, account: account, email: 'care@example.com',
                           aliases: ['nonprofit@example.com', 'info@example.com'])
  end
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def incoming_email(email_attributes)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, content_type: :incoming_email,
                     content_attributes: { email: email_attributes })
  end

  def perform
    described_class.new(channel: channel, conversation: conversation).perform
  end

  it 'returns nil when the conversation has no incoming email message' do
    expect(perform).to be_nil
  end

  it 'returns the channel-owned address named in To' do
    incoming_email(to: ['nonprofit@example.com'], cc: [], bcc: [])

    expect(perform).to eq('nonprofit@example.com')
  end

  it 'returns the channel-owned address named in Cc' do
    incoming_email(to: ['someone@example.com'], cc: ['info@example.com'], bcc: [])

    expect(perform).to eq('info@example.com')
  end

  it 'returns the channel-owned address named in Bcc' do
    incoming_email(to: ['someone@example.com'], cc: [], bcc: ['nonprofit@example.com'])

    expect(perform).to eq('nonprofit@example.com')
  end

  it 'returns the channel-owned address named in the stored X-Original-To header' do
    incoming_email(to: ['someone@example.com'], cc: [], bcc: [], headers: { 'x-original-to' => 'info@example.com' })

    expect(perform).to eq('info@example.com')
  end

  it 'canonicalises a case-different or plus-addressed match to the configured address' do
    incoming_email(to: ['NonProfit+donation@Example.com'], cc: [], bcc: [])

    expect(perform).to eq('nonprofit@example.com')
  end

  it 'returns nil when no recipient belongs to the channel' do
    incoming_email(to: ['stranger@example.com'], cc: ['another@example.com'], bcc: [])

    expect(perform).to be_nil
  end

  # This is the correction. The deployed field was written once, on conversation creation.
  it 'follows the LATEST inbound message, so an earlier alias cannot go stale' do
    incoming_email(to: ['nonprofit@example.com'], cc: [], bcc: [])
    incoming_email(to: ['care@example.com'], cc: [], bcc: [])

    expect(perform).to eq('care@example.com')
  end

  it 'ignores outgoing messages entirely' do
    incoming_email(to: ['nonprofit@example.com'], cc: [], bcc: [])
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, content_attributes: { email: { to: ['care@example.com'] } })

    expect(perform).to eq('nonprofit@example.com')
  end

  it 'ignores incoming messages that carry no email envelope' do
    incoming_email(to: ['nonprofit@example.com'], cc: [], bcc: [])
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

    expect(perform).to eq('nonprofit@example.com')
  end

  it 'reads no conversation-level attribute' do
    conversation.update!(additional_attributes: { 'inbound_recipient_email' => 'info@example.com' })

    expect(perform).to be_nil
  end
end
