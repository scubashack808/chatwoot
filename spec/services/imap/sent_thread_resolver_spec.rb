require 'rails_helper'

# M06: "Discovered Sent reply threads once by exact references/identity."
#
# The plan is explicit that the first Sent PR "threads only messages that unambiguously reference
# an existing Chatwoot conversation" and that it "does not fabricate a new contact/conversation for
# an unthreaded message sent in another client". These examples are the negative half of that rule
# as much as the positive half.
RSpec.describe Imap::SentThreadResolver do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:other_conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  def mail_with(headers)
    Mail.new do
      headers.each { |key, value| header[key] = value }
      body 'sent from another client'
    end
  end

  describe 'exact reference to an existing conversation' do
    it 'resolves through In-Reply-To pointing at a stored message source_id' do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, source_id: 'customer-1@example.test')

      resolved = described_class.new(inbox: inbox, mail: mail_with('In-Reply-To' => '<customer-1@example.test>')).perform

      expect(resolved.conversation).to eq conversation
      expect(resolved.reason).to eq 'in_reply_to'
    end

    it 'resolves through References pointing at a stored message source_id' do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, source_id: 'customer-2@example.test')

      resolved = described_class.new(
        inbox: inbox,
        mail: mail_with('References' => '<unknown@example.test> <customer-2@example.test>')
      ).perform

      expect(resolved.conversation).to eq conversation
      expect(resolved.reason).to eq 'references'
    end

    it 'resolves through the conversation UUID address Chatwoot puts in its own replies' do
      resolved = described_class.new(
        inbox: inbox,
        mail: mail_with('References' => "<account/#{account.id}/conversation/#{conversation.uuid}@example.test>")
      ).perform

      expect(resolved.conversation).to eq conversation
      expect(resolved.reason).to eq 'conversation_uuid'
    end
  end

  describe 'anything less than unambiguous' do
    it 'refuses a message with no In-Reply-To and no References' do
      resolved = described_class.new(inbox: inbox, mail: mail_with('Subject' => 'cold outreach')).perform

      expect(resolved.conversation).to be_nil
      expect(resolved.reason).to eq 'unthreaded'
    end

    it 'refuses a message whose references match nothing in Chatwoot' do
      resolved = described_class.new(inbox: inbox, mail: mail_with('References' => '<nothing@example.test>')).perform

      expect(resolved.conversation).to be_nil
      expect(resolved.reason).to eq 'unthreaded'
    end

    it 'refuses when references point at two different conversations rather than guessing one' do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, source_id: 'first@example.test')
      create(:message, account: account, inbox: inbox, conversation: other_conversation,
                       message_type: :incoming, source_id: 'second@example.test')

      resolved = described_class.new(
        inbox: inbox,
        mail: mail_with('References' => '<first@example.test> <second@example.test>')
      ).perform

      expect(resolved.conversation).to be_nil
      expect(resolved.reason).to eq 'ambiguous'
    end

    it 'refuses a reference that belongs to a different inbox' do
      other_inbox_channel = create(:channel_email, :imap_email, account: account)
      other_inbox_conversation = create(:conversation, account: account, inbox: other_inbox_channel.inbox, contact: contact)
      create(:message, account: account, inbox: other_inbox_channel.inbox, conversation: other_inbox_conversation,
                       message_type: :incoming, source_id: 'elsewhere@example.test')

      resolved = described_class.new(inbox: inbox, mail: mail_with('References' => '<elsewhere@example.test>')).perform

      expect(resolved.conversation).to be_nil
      expect(resolved.reason).to eq 'unthreaded'
    end
  end
end
