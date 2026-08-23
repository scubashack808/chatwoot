require 'rails_helper'

RSpec.describe Imap::FolderDiscoveryService do
  let(:account) { create(:account) }
  # A cPanel/Dovecot shaped server, matching the production inventory.
  let(:cpanel_folders) do
    [
      mailbox('INBOX', [:Haschildren]),
      mailbox('INBOX.Archive', [:Archive, :Hasnochildren]),
      mailbox('INBOX.Sent', [:Sent, :Hasnochildren]),
      mailbox('INBOX.spam', [:Junk, :Hasnochildren]),
      mailbox('INBOX.Trash', [:Trash, :Hasnochildren]),
      mailbox('INBOX.Blocked', [:Hasnochildren])
    ]
  end
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: channel.inbox.id) }

  def mailbox(name, attrs, delim: '.')
    Net::IMAP::MailboxList.new(attrs, delim, name)
  end

  before do
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:list).with('', '*').and_return(cpanel_folders)
  end

  after { Redis::Alfred.delete(lease_key) }

  describe '#perform' do
    it 'returns every listed folder with its exact name, delimiter and attributes' do
      result = described_class.new(channel: channel).perform

      expect(result.folders.map { |folder| folder[:name] }).to include('INBOX.Archive', 'INBOX.Blocked')
      expect(result.folders.find { |folder| folder[:name] == 'INBOX.Archive' }[:delimiter]).to eq '.'
      expect(result.folders.find { |folder| folder[:name] == 'INBOX.Archive' }[:attributes]).to include('archive')
    end

    it 'closes the connection after discovery' do
      described_class.new(channel: channel).perform

      expect(imap).to have_received(:disconnect)
    end

    it 'releases the lease after discovery' do
      described_class.new(channel: channel).perform

      expect(Redis::Alfred.exists?(lease_key)).to be false
    end

    it 'defers instead of opening a second connection when the lease is held' do
      Imap::Lease.new(inbox_id: channel.inbox.id, ttl: 30).acquire

      expect { described_class.new(channel: channel).perform }
        .to raise_error(Imap::Lease::LeaseNotAcquiredError)
    end
  end

  describe 'exactly one match' do
    it 'resolves each role deterministically' do
      result = described_class.new(channel: channel).perform

      expect(result.for_role('archive').status).to eq 'discovered'
      expect(result.for_role('archive').selected).to eq 'INBOX.Archive'
      expect(result.for_role('trash').selected).to eq 'INBOX.Trash'
      expect(result.for_role('spam').selected).to eq 'INBOX.spam'
      expect(result.for_role('sent').selected).to eq 'INBOX.Sent'
      expect(result.for_role('archive')).to be_available
    end

    it 'normalises special use attributes case insensitively' do
      allow(imap).to receive(:list).with('', '*').and_return([mailbox('INBOX.Archive', [:ARCHIVE])])

      expect(described_class.new(channel: channel).perform.for_role('archive').selected).to eq 'INBOX.Archive'
    end
  end

  describe 'zero matches' do
    it 'marks the role unavailable rather than guessing a folder by name' do
      allow(imap).to receive(:list).with('', '*')
                                   .and_return([mailbox('INBOX', [:Haschildren]), mailbox('INBOX.Archive', [:Hasnochildren])])

      role = described_class.new(channel: channel).perform.for_role('archive')

      expect(role.status).to eq 'unavailable'
      expect(role.selected).to be_nil
      expect(role).not_to be_available
      expect(role.candidates).to be_empty
    end

    it 'never falls back to an alphabetical or provider-name guess' do
      allow(imap).to receive(:list).with('', '*')
                                   .and_return([mailbox('INBOX.Archives', [:Hasnochildren]), mailbox('INBOX.Trash', [:Hasnochildren])])

      result = described_class.new(channel: channel).perform

      expect(result.for_role('archive').selected).to be_nil
      expect(result.for_role('trash').selected).to be_nil
    end
  end

  describe 'multiple matches' do
    # This is the live Info - EH shape: two folders both marked \Archive.
    let(:ambiguous_folders) do
      cpanel_folders + [mailbox('INBOX.Archives', [:Archive, :Hasnochildren])]
    end

    before { allow(imap).to receive(:list).with('', '*').and_return(ambiguous_folders) }

    it 'marks the role ambiguous and selects nothing' do
      role = described_class.new(channel: channel).perform.for_role('archive')

      expect(role.status).to eq 'ambiguous'
      expect(role.selected).to be_nil
      expect(role).not_to be_available
    end

    it 'reports both candidates so an administrator can choose one' do
      role = described_class.new(channel: channel).perform.for_role('archive')

      expect(role.candidates).to contain_exactly('INBOX.Archive', 'INBOX.Archives')
    end

    it 'leaves the unambiguous roles resolved' do
      result = described_class.new(channel: channel).perform

      expect(result.for_role('trash').status).to eq 'discovered'
    end
  end

  describe 'administrator overrides' do
    before do
      allow(imap).to receive(:list).with('', '*')
                                   .and_return(cpanel_folders + [mailbox('INBOX.Archives', [:Archive, :Hasnochildren])])
    end

    it 'uses a valid override to resolve an otherwise ambiguous role' do
      channel.update!(mailbox_sync_config: { 'mode' => 'observe', 'folder_overrides' => { 'archive' => 'INBOX.Archives' } })

      role = described_class.new(channel: channel).perform.for_role('archive')

      expect(role.status).to eq 'overridden'
      expect(role.selected).to eq 'INBOX.Archives'
      expect(role).to be_available
    end

    it 'accepts an override onto a folder with no special use attribute' do
      channel.update!(mailbox_sync_config: { 'folder_overrides' => { 'archive' => 'INBOX.Blocked' } })

      expect(described_class.new(channel: channel).perform.for_role('archive').selected).to eq 'INBOX.Blocked'
    end

    it 'rejects an override that no longer exists on the server and leaves the role unavailable' do
      # A server change made after the override was saved, so it must bypass the save-time check.
      channel.update_column(:mailbox_sync_config, # rubocop:disable Rails/SkipsModelValidations
                            { 'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => { 'archive' => 'INBOX.Deleted.Folder' } })

      role = described_class.new(channel: channel).perform.for_role('archive')

      expect(role.status).to eq 'invalid_override'
      expect(role.selected).to be_nil
      expect(role).not_to be_available
    end

    it 'rejects an override onto a folder that cannot be selected' do
      allow(imap).to receive(:list).with('', '*')
                                   .and_return(cpanel_folders + [mailbox('INBOX.Container', [:Noselect])])
      # A server change made after the override was saved, so it must bypass the save-time check.
      channel.update_column(:mailbox_sync_config, # rubocop:disable Rails/SkipsModelValidations
                            { 'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => { 'archive' => 'INBOX.Container' } })

      expect(described_class.new(channel: channel).perform.for_role('archive').status).to eq 'invalid_override'
    end

    it 'matches the override exactly and is not fooled by a case variant' do
      # A server change made after the override was saved, so it must bypass the save-time check.
      channel.update_column(:mailbox_sync_config, # rubocop:disable Rails/SkipsModelValidations
                            { 'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => { 'archive' => 'inbox.archives' } })

      expect(described_class.new(channel: channel).perform.for_role('archive').status).to eq 'invalid_override'
    end
  end

  describe 'gmail shaped server' do
    let(:gmail_folders) do
      [
        mailbox('INBOX', [:Hasnochildren], delim: '/'),
        mailbox('[Gmail]/All Mail', [:All, :Hasnochildren], delim: '/'),
        mailbox('[Gmail]/Sent Mail', [:Sent, :Hasnochildren], delim: '/'),
        mailbox('[Gmail]/Spam', [:Junk, :Hasnochildren], delim: '/'),
        mailbox('[Gmail]/Trash', [:Trash, :Hasnochildren], delim: '/')
      ]
    end

    before { allow(imap).to receive(:list).with('', '*').and_return(gmail_folders) }

    it 'preserves exact folder names containing spaces and brackets' do
      result = described_class.new(channel: channel).perform

      expect(result.for_role('sent').selected).to eq '[Gmail]/Sent Mail'
      expect(result.for_role('trash').selected).to eq '[Gmail]/Trash'
      expect(result.for_role('spam').selected).to eq '[Gmail]/Spam'
    end

    # Gmail archive removes the Inbox label; \All is not an ordinary Archive move target.
    it 'does not treat the All Mail folder as an Archive folder' do
      expect(described_class.new(channel: channel).perform.for_role('archive').status).to eq 'unavailable'
    end
  end

  describe '#to_h' do
    it 'renders a payload with no credentials in it' do
      payload = described_class.new(channel: channel).perform.to_h

      expect(payload[:roles]['archive'][:selected]).to eq 'INBOX.Archive'
      expect(payload[:folders]).to be_an(Array)
      expect(payload.to_s).not_to include(channel.imap_password)
      expect(payload.to_s).not_to match(/password|token|secret/i)
    end
  end
end
