require 'rails_helper'

RSpec.describe Channel::Email do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }

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
