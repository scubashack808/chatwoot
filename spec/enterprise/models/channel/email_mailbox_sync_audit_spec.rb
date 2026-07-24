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

    it 'never writes a credential into the audit entry' do
      channel.update!(mailbox_sync_config: { 'mode' => 'active', 'folder_overrides' => { 'trash' => 'INBOX.Trash' } })

      serialized = Enterprise::AuditLog.last.audited_changes['mailbox_sync_config'].to_s

      expect(serialized).not_to include(channel.imap_password)
      expect(serialized).not_to match(/password|token|secret/i)
    end
  end
end
