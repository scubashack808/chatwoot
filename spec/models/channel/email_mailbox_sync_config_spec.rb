require 'rails_helper'

RSpec.describe Channel::Email do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: channel.inbox.id) }
  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archives'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash'),
      Net::IMAP::MailboxList.new([:Junk, :Hasnochildren], '.', 'INBOX.spam')
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

  describe 'the stored column default' do
    it 'starts every inbox off' do
      expect(channel.reload.mailbox_sync_config).to eq(
        'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => {}
      )
    end

    it 'reads back as the off contract' do
      expect(channel.mailbox_sync).to be_off
      expect(channel.mailbox_sync.provider_mutation_allowed?).to be false
    end

    it 'applies the off default to a row created before the column existed' do
      # Simulates an existing production row: the column default is what backfills it.
      ActiveRecord::Base.connection.execute(
        "UPDATE channel_email SET mailbox_sync_config = DEFAULT WHERE id = #{channel.id}"
      )

      expect(channel.reload.mailbox_sync).to be_off
    end
  end

  describe 'validation' do
    it 'accepts a valid configuration' do
      channel.mailbox_sync_config = { 'mode' => 'observe', 'sent_mode' => 'append',
                                      'folder_overrides' => { 'archive' => 'INBOX.Archives' } }

      expect(channel).to be_valid
    end

    it 'rejects an unknown mode' do
      channel.mailbox_sync_config = { 'mode' => 'delete_everything' }

      expect(channel).not_to be_valid
      expect(channel.errors[:mailbox_sync_config].join).to match(/mode/)
    end

    it 'rejects an unknown top level key' do
      channel.mailbox_sync_config = { 'mode' => 'off', 'imap_password' => 'sneaky' }

      expect(channel).not_to be_valid
      expect(channel.errors[:mailbox_sync_config].join).to match(/imap_password/)
    end

    it 'rejects an unknown folder role' do
      channel.mailbox_sync_config = { 'folder_overrides' => { 'drafts' => 'INBOX.Drafts' } }

      expect(channel).not_to be_valid
      expect(channel.errors[:mailbox_sync_config].join).to match(/drafts/)
    end

    it 'rejects an unknown sent mode' do
      channel.mailbox_sync_config = { 'sent_mode' => 'whatever' }

      expect(channel).not_to be_valid
    end

    it 'persists a valid configuration' do
      channel.update!(mailbox_sync_config: { 'mode' => 'active', 'folder_overrides' => { 'trash' => 'INBOX.Trash' } })

      expect(channel.reload.mailbox_sync.mode).to eq 'active'
      expect(channel.reload.mailbox_sync.override_for(:trash)).to eq 'INBOX.Trash'
    end

    it 'does not persist an invalid configuration' do
      expect { channel.update!(mailbox_sync_config: { 'mode' => 'nope' }) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(channel.reload.mailbox_sync).to be_off
    end
  end

  describe 'mode transitions' do
    it 'moves off to observe to active and back to off' do
      %w[observe active off].each do |mode|
        channel.update!(mailbox_sync_config: channel.mailbox_sync.to_h.merge('mode' => mode))
        expect(channel.reload.mailbox_sync.mode).to eq mode
      end
    end

    it 'keeps folder overrides across a mode change' do
      channel.update!(mailbox_sync_config: { 'mode' => 'observe', 'folder_overrides' => { 'spam' => 'INBOX.spam' } })
      channel.update!(mailbox_sync_config: channel.mailbox_sync.to_h.merge('mode' => 'active'))

      expect(channel.reload.mailbox_sync.override_for(:spam)).to eq 'INBOX.spam'
    end
  end

  describe 'server verification scope' do
    it 'does not contact the mail server when only the mode changes' do
      channel.update!(mailbox_sync_config: { 'mode' => 'observe' })

      expect(imap).not_to have_received(:list)
    end

    it 'contacts the mail server when a folder override changes' do
      channel.update!(mailbox_sync_config: { 'folder_overrides' => { 'archive' => 'INBOX.Archives' } })

      expect(imap).to have_received(:list).with('', '*')
    end

    it 'refuses an override that is not selectable on the server' do
      channel.mailbox_sync_config = { 'folder_overrides' => { 'archive' => 'INBOX.Gone' } }

      expect(channel).not_to be_valid
      expect(channel.errors[:mailbox_sync_config].join).to match(/INBOX.Gone/)
    end
  end

  describe 'EDITABLE_ATTRS' do
    it 'permits mailbox_sync_config as a nested object through the existing inbox update path' do
      expect(described_class::EDITABLE_ATTRS).to include(mailbox_sync_config: {})
    end
  end
end
