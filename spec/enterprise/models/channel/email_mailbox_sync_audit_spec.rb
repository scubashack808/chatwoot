require 'rails_helper'

RSpec.describe Channel::Email do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: channel.inbox.id) }
  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archives'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash')
    ]
  end

  # Saving a folder override re-reads the server folder list, so the LIST is stubbed here.
  before do
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:list).with('', '*').and_return(folders)
  end

  after { Redis::Alfred.delete(lease_key) }

  describe 'mailbox sync configuration auditing' do
    it 'records the change through the existing channel audit seam' do
      channel # create before counting

      expect do
        channel.update!(mailbox_sync_config: { 'mode' => 'observe', 'folder_overrides' => { 'archive' => 'INBOX.Archives' } })
      end.to change(Enterprise::AuditLog, :count).by(1)

      entry = Enterprise::AuditLog.last
      expect(entry.auditable_type).to eq 'Inbox'
      expect(entry.auditable_id).to eq channel.inbox.id
      expect(entry.action).to eq 'update'
      expect(entry.audited_changes).to have_key('mailbox_sync_config')
    end

    it 'records the mode transition values so the change is reviewable' do
      channel.update!(mailbox_sync_config: { 'mode' => 'observe' })

      change = Enterprise::AuditLog.last.audited_changes['mailbox_sync_config']

      expect(change.first['mode']).to eq 'off'
      expect(change.last['mode']).to eq 'observe'
    end

    it 'persists actual Sent import checkpoints without logging configuration changes' do
      channel.update!(mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'provider_managed' })
      original_config = channel.reload.mailbox_sync_config.deep_dup
      sent_mailbox = instance_double(Imap::SentMailbox, mailbox: 'INBOX.Sent', uidvalidity: 7001)
      allow(sent_mailbox).to receive(:search_since).and_return((1..101).to_a)

      expect do
        progress = Imap::SentImportProgress.new(channel: channel, sent_mailbox: sent_mailbox, interval: 1)
        selected = progress.select(limit: 100)
        expect(channel.reload.sent_import_progress['pending_uids']).to eq((1..101).to_a)
        progress.acknowledge(uids: selected, retry_uids: [1])
        expect(channel.reload.sent_import_progress).to include('pending_uids' => [101], 'retry_uids' => [1])

        resumed = Imap::SentImportProgress.new(channel: channel.reload, sent_mailbox: sent_mailbox, interval: 1)
        selected = resumed.select(limit: 100)
        expect(selected).to eq [101, 1]
        resumed.acknowledge(uids: selected, retry_uids: [])
      end.not_to change(Enterprise::AuditLog, :count)

      expect(channel.reload.sent_import_progress).to include('pending_uids' => [], 'retry_uids' => [])
      expect(channel.mailbox_sync_config).to eq original_config
    end

    it 'never writes a credential into the audit entry' do
      channel.update!(mailbox_sync_config: { 'mode' => 'active', 'folder_overrides' => { 'trash' => 'INBOX.Trash' } })

      serialized = Enterprise::AuditLog.last.audited_changes['mailbox_sync_config'].to_s

      expect(serialized).not_to include(channel.imap_password)
      expect(serialized).not_to match(/password|token|secret/i)
    end
  end
end
