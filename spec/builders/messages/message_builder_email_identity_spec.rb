require 'rails_helper'

# Row 09 behaviours A04 (server rejects a From address the channel does not own) and A06
# (our own addresses never leak into To or Cc, whatever the client).
RSpec.describe Messages::MessageBuilder do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:channel) do
    create(:channel_email, account: account, email: 'care@example.com',
                           aliases: ['nonprofit@example.com', 'info@example.com'])
  end
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def build_message(params)
    described_class.new(user, conversation, ActionController::Parameters.new(params)).perform
  end

  describe 'the agent-chosen From address' do
    it 'accepts the channel primary' do
      message = build_message(content: 'hi', content_attributes: { from_email: 'care@example.com' })

      expect(message.content_attributes['from_email']).to eq('care@example.com')
    end

    it 'accepts one of the channel aliases' do
      message = build_message(content: 'hi', content_attributes: { from_email: 'nonprofit@example.com' })

      expect(message.content_attributes['from_email']).to eq('nonprofit@example.com')
    end

    it 'rejects an address the channel does not own' do
      expect do
        build_message(content: 'hi', content_attributes: { from_email: 'attacker@evil.com' })
      end.to raise_error(StandardError, /from address/i)
    end

    it 'rejects another channel address that this channel does not own' do
      create(:channel_email, account: account, email: 'sales@example.com')

      expect do
        build_message(content: 'hi', content_attributes: { from_email: 'sales@example.com' })
      end.to raise_error(StandardError, /from address/i)
    end

    it 'creates no message at all when the From address is refused' do
      expect do
        build_message(content: 'hi', content_attributes: { from_email: 'attacker@evil.com' })
      rescue StandardError
        nil
      end.not_to change(Message, :count)
    end

    it 'leaves a message without a From override alone' do
      message = build_message(content: 'hi')

      expect(message.content_attributes['from_email']).to be_nil
    end
  end

  describe 'our own addresses in the recipient lists' do
    it 'strips the channel primary from cc' do
      message = build_message(content: 'hi', cc_emails: 'customer@example.com,care@example.com')

      expect(message.content_attributes['cc_emails']).to eq(['customer@example.com'])
    end

    it 'strips every channel alias from cc, case-insensitively' do
      message = build_message(content: 'hi', cc_emails: 'NonProfit@Example.com,customer@example.com,INFO@example.com')

      expect(message.content_attributes['cc_emails']).to eq(['customer@example.com'])
    end

    it 'strips the forward-to address from cc' do
      message = build_message(content: 'hi', cc_emails: "customer@example.com,#{channel.forward_to_email}")

      expect(message.content_attributes['cc_emails']).to eq(['customer@example.com'])
    end

    it 'strips our own addresses from to and bcc as well' do
      message = build_message(content: 'hi',
                              to_emails: 'customer@example.com,nonprofit@example.com',
                              bcc_emails: 'care@example.com,partner@example.com')

      expect(message.content_attributes['to_emails']).to eq(['customer@example.com'])
      expect(message.content_attributes['bcc_emails']).to eq(['partner@example.com'])
    end

    it 'de-duplicates repeated recipients case-insensitively' do
      message = build_message(content: 'hi', cc_emails: 'Customer@example.com,customer@example.com,other@example.com')

      expect(message.content_attributes['cc_emails']).to eq(['Customer@example.com', 'other@example.com'])
    end

    it 'leaves recipients that are not ours untouched' do
      message = build_message(content: 'hi', cc_emails: 'one@example.com,two@example.com')

      expect(message.content_attributes['cc_emails']).to eq(['one@example.com', 'two@example.com'])
    end
  end
end
