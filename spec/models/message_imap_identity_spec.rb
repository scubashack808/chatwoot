require 'rails_helper'

RSpec.describe Message do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }
  let(:identity) { Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']) }
  let(:receipt) { { 'operation_id' => 123, 'identity' => identity.to_h } }

  describe '#write_imap_identity!' do
    it 'stores the identity under the imap namespace' do
      message.write_imap_identity!(identity)

      expect(message.reload.external_source_ids['imap']).to include(
        'mailbox' => 'INBOX', 'uidvalidity' => 42, 'uid' => 7
      )
    end

    it 'reads back as an identity object' do
      message.write_imap_identity!(identity)

      expect(message.reload.imap_identity.uid).to eq 7
    end

    it 'never overwrites another integration source id' do
      message.update!(external_source_ids: { 'slack' => 'cw-origin-123' })

      message.write_imap_identity!(identity)

      expect(message.reload.external_source_ids['slack']).to eq 'cw-origin-123'
      expect(message.reload.external_source_ids['imap']).to be_present
    end

    it 'merges over a previous imap identity rather than appending a second one' do
      message.write_imap_identity!(identity)
      message.write_imap_identity!(Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 8))

      expect(message.reload.external_source_ids['imap']['uid']).to eq 8
      expect(message.reload.external_source_ids.keys).to eq ['imap']
    end

    it 'writes the receipt and identity together without replacing other integration keys' do
      message.update!(external_source_ids: { 'slack' => 'cw-origin-123' })
      allow(message).to receive(:update_columns).and_call_original

      message.write_imap_identity!(identity, mailbox_operation_receipt: receipt)

      expect(message).to have_received(:update_columns).once.with(
        external_source_ids: { 'slack' => 'cw-origin-123', 'imap' => identity.to_h.merge('mailbox_operation_receipt' => receipt) }
      )
      expect(message.reload.external_source_ids['imap']['mailbox_operation_receipt']).to eq receipt
      expect(message.imap_identity.to_h).to eq identity.to_h
      expect(message.external_source_ids['slack']).to eq 'cw-origin-123'
    end

    it 'invalidates the receipt when an ordinary identity write replaces the namespace' do
      message.write_imap_identity!(identity, mailbox_operation_receipt: receipt)

      message.write_imap_identity!(identity)

      expect(message.reload.external_source_ids['imap']).to eq identity.to_h
    end

    it 'replaces the previous receipt rather than appending receipts' do
      message.write_imap_identity!(identity, mailbox_operation_receipt: receipt)
      replacement = receipt.merge('operation_id' => 456)

      message.write_imap_identity!(identity, mailbox_operation_receipt: replacement)

      expect(message.reload.external_source_ids['imap']['mailbox_operation_receipt']).to eq replacement
    end

    it 'leaves the previous identity without a receipt when the database write fails' do
      message.write_imap_identity!(identity)
      changed_identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 8)
      allow(message).to receive(:update_columns).and_raise(ActiveRecord::StatementInvalid, 'injected write failure')

      expect do
        message.write_imap_identity!(changed_identity, mailbox_operation_receipt: receipt)
      end.to(raise_error { |error| expect(error.class.name).to eq 'ActiveRecord::StatementInvalid' })

      expect(message.reload.external_source_ids['imap']).to eq identity.to_h
    end

    # Identity metadata is internal synchronisation state. An ordinary update would notify
    # contacts and fan out to automations, bots, webhooks and CRM processors.
    it 'does not dispatch a message updated event' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      message.write_imap_identity!(identity, mailbox_operation_receipt: receipt)

      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
        .with(described_class::MESSAGE_UPDATED, anything, hash_including(:message))
    end

    it 'does not change the updated_at timestamp' do
      message
      expect { message.write_imap_identity!(identity, mailbox_operation_receipt: receipt) }.not_to(change { message.reload.updated_at })
    end

    it 'takes a row lock while merging' do
      allow(message).to receive(:with_lock).and_call_original

      message.write_imap_identity!(identity, mailbox_operation_receipt: receipt)

      expect(message).to have_received(:with_lock)
    end
  end

  describe '#imap_identity' do
    it 'is nil when no identity has been recorded' do
      expect(message.imap_identity).to be_nil
    end

    it 'is nil when another integration wrote source ids but imap did not' do
      message.update!(external_source_ids: { 'slack' => 'cw-origin-123' })

      expect(message.reload.imap_identity).to be_nil
    end
  end

  describe 'payload stripping' do
    before { message.write_imap_identity!(identity, mailbox_operation_receipt: receipt) }

    it 'keeps the imap namespace out of push_event_data' do
      expect(message.reload.push_event_data[:external_source_ids]).not_to have_key('imap')
    end

    it 'keeps the imap namespace out of the webhook payload' do
      expect(message.reload.webhook_push_event_data[:external_source_ids]).not_to have_key('imap')
    end

    it 'still ships other integration source ids' do
      message.update!(external_source_ids: message.external_source_ids.merge('slack' => 'cw-origin-123'))

      expect(message.reload.push_event_data[:external_source_ids]).to eq('slack' => 'cw-origin-123')
    end

    it 'leaves push_event_data untouched for a message with no imap identity' do
      other = create(:message, account: account, inbox: inbox, conversation: conversation)

      expect(other.push_event_data[:external_source_ids]).to eq other.external_source_ids
    end

    it 'never leaks a uid through the serialised payload' do
      expect(message.reload.push_event_data.to_s).not_to include('uidvalidity', 'mailbox_operation_receipt')
    end
  end

  describe 'conversation payloads that embed a message' do
    before { message.write_imap_identity!(identity, mailbox_operation_receipt: receipt) }

    it 'keeps the imap namespace out of the conversation push payload' do
      payload = Conversations::EventDataPresenter.new(conversation.reload).push_data

      expect(payload.to_s).not_to include('uidvalidity', 'mailbox_operation_receipt')
    end

    it 'keeps the imap namespace out of the conversation webhook payload' do
      payload = Conversations::EventDataPresenter.new(conversation.reload).webhook_data

      expect(payload.to_s).not_to include('uidvalidity', 'mailbox_operation_receipt')
    end
  end
end
