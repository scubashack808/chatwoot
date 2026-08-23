require 'rails_helper'

RSpec.describe Conversations::DeleteService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:ip) { '127.0.0.1' }
  let(:service) { described_class.new(conversation: conversation, user: user, ip: ip) }

  context 'when deleting an email conversation' do
    let(:inbox) { create(:channel_email, :imap_email, account: account).inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }

    it 'refuses local hard deletion and directs the caller to Trash' do
      expect(Imap::DeletedMessageTracker).not_to receive(:new)

      expect { service.perform }
        .to raise_error(CustomExceptions::EmailConversationHardDelete, /Trash/)
      expect(DeleteObjectJob).not_to have_been_enqueued
    end
  end

  context 'when deleting a non-email conversation' do
    let(:conversation) { create(:conversation, account: account) }

    it 'enqueues the deletion job without recording message source ids' do
      expect(Imap::DeletedMessageTracker).not_to receive(:new)

      expect { service.perform }.to have_enqueued_job(DeleteObjectJob).with(conversation, user, ip)
    end
  end
end
