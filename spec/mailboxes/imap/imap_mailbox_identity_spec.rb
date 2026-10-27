require 'rails_helper'

RSpec.describe Imap::ImapMailbox do
  include ActionMailbox::TestHelper

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:raw) { Rails.root.join('spec/fixtures/files/only_text.eml').read }
  let(:mail) { Mail.read_from_string(raw) }

  def fetched(uid: 91, uidvalidity: 555, mailbox: 'INBOX', roles: ['inbox'], provider_id: nil)
    Imap::FetchedMessage.new(mail: mail, mailbox: mailbox, uidvalidity: uidvalidity, uid: uid, roles: roles, provider_id: provider_id)
  end

  describe 'persisting identity at ingestion' do
    it 'records the server identity on the created message' do
      described_class.new.process(fetched, channel)

      identity = channel.inbox.messages.last.imap_identity

      expect(identity.mailbox).to eq 'INBOX'
      expect(identity.uidvalidity).to eq 555
      expect(identity.uid).to eq 91
      expect(identity.roles).to eq ['inbox']
    end

    it 'records the provider stable id when the server offered one' do
      described_class.new.process(fetched(provider_id: '1234567890'), channel)

      expect(channel.inbox.messages.last.imap_identity.provider_id).to eq '1234567890'
    end

    it 'never stores a sequence number' do
      described_class.new.process(fetched, channel)

      stored = channel.inbox.messages.last.external_source_ids['imap']

      expect(stored.to_s).not_to match(/seqno|sequence/i)
    end

    it 'keeps the identity out of the broadcast payload for the created message' do
      described_class.new.process(fetched, channel)

      message = channel.inbox.messages.last

      expect(message.push_event_data[:external_source_ids]).not_to have_key('imap')
      expect(message.push_event_data.to_s).not_to include('uidvalidity')
    end

    it 'still creates the conversation and message as before' do
      expect { described_class.new.process(fetched, channel) }
        .to change(Conversation, :count).by(1)
        .and change(Message, :count).by(1)
    end

    it 'still accepts a bare Mail object, so nothing that has not been migrated breaks' do
      expect { described_class.new.process(mail, channel) }.to change(Message, :count).by(1)

      expect(channel.inbox.messages.last.imap_identity).to be_nil
    end
  end

  describe 'importing from the Junk folder' do
    let(:junk) { fetched(mailbox: 'INBOX.spam', roles: ['spam']) }

    it 'creates a resolved, junk-marked conversation that stays resolved after its message commits' do
      described_class.new.process(junk, channel, junk: true)

      conversation = channel.inbox.conversations.last
      expect(conversation.reload).to be_resolved
      expect(conversation).to be_junk_import
      expect(conversation.messages.last.imap_identity.roles).to eq ['spam']
    end

    it 'stays resolved on an inbox with an active bot, so no bot takes on the spam' do
      create(:agent_bot_inbox, inbox: channel.inbox, agent_bot: create(:agent_bot, account: account))

      described_class.new.process(junk, channel, junk: true)

      expect(channel.inbox.conversations.last.reload).to be_resolved
    end

    it 'adds junk that threads into an existing conversation without marking it junk, and reopens it' do
      existing = create(:conversation, account: account, inbox: channel.inbox, status: :resolved)
      create(:message, conversation: existing, account: account, inbox: channel.inbox, source_id: 'thread@example.com')
      mail.in_reply_to = 'thread@example.com'

      expect { described_class.new.process(junk, channel, junk: true) }.not_to change(Conversation, :count)

      expect(existing.reload).to be_open
      expect(existing).not_to be_junk_import
    end

    it 'reopens a junk conversation when ordinary inbox mail threads into it' do
      described_class.new.process(junk, channel, junk: true)
      conversation = channel.inbox.conversations.last
      reply = Mail.new(from: 'text@example.com', to: 'care@example.com', subject: 'Re', body: 'real reply',
                       message_id: '<reply@example.com>', in_reply_to: mail.message_id)

      described_class.new.process(reply, channel)

      expect(conversation.reload).to be_open
    end
  end
end
