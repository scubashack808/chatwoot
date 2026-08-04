require 'rails_helper'

RSpec.describe Imap::MailboxTargets do
  let(:config) { Imap::MailboxSyncConfig.default }

  def folder(attributes, name)
    Net::IMAP::MailboxList.new(attributes, '.', name)
  end

  describe 'a standard IMAP server' do
    let(:listing) do
      [
        folder([:Haschildren], 'INBOX'),
        folder([:Archive, :Hasnochildren], 'INBOX.Archive'),
        folder([:Trash, :Hasnochildren], 'INBOX.Trash'),
        folder([:Junk, :Hasnochildren], 'INBOX.spam')
      ]
    end

    it 'resolves every action to its special-use folder' do
      targets = described_class.new(listing: listing, config: config)

      expect(targets.target_for('archive')).to eq 'INBOX.Archive'
      expect(targets.target_for('trash')).to eq 'INBOX.Trash'
      expect(targets.target_for('spam')).to eq 'INBOX.spam'
      expect(targets).to be_available
      expect(targets.unavailable).to be_empty
    end

    it 'reports archive unavailable when two folders both claim the role' do
      ambiguous = listing + [folder([:Archive, :Hasnochildren], 'INBOX.Archives')]
      targets = described_class.new(listing: ambiguous, config: config)

      expect(targets.target_for('archive')).to be_nil
      expect(targets.unavailable).to eq ['archive']
      expect(targets).not_to be_available
    end

    it 'resolves an ambiguous role once an override names the folder' do
      ambiguous = listing + [folder([:Archive, :Hasnochildren], 'INBOX.Archives')]
      overridden = Imap::MailboxSyncConfig.parse('folder_overrides' => { 'archive' => 'INBOX.Archives' })
      targets = described_class.new(listing: ambiguous, config: overridden)

      expect(targets.target_for('archive')).to eq 'INBOX.Archives'
      expect(targets).to be_available
    end
  end

  # Gmail is the case that makes a folder-shaped check wrong. It has no \Archive folder and never
  # will, so anything asking "does the archive role resolve" reports a healthy Gmail inbox as
  # broken. Archive there strips the Inbox label and resolves through \All.
  describe 'Gmail' do
    let(:listing) do
      [
        folder([:Haschildren], 'INBOX'),
        folder([:All, :Hasnochildren], '[Gmail]/All Mail'),
        folder([:Trash, :Hasnochildren], '[Gmail]/Trash'),
        folder([:Junk, :Hasnochildren], '[Gmail]/Spam')
      ]
    end

    it 'resolves archive through All Mail and reports the inbox usable' do
      targets = described_class.new(listing: listing, config: config, gmail: true)

      expect(targets.target_for('archive')).to eq '[Gmail]/All Mail'
      expect(targets.target_for('trash')).to eq '[Gmail]/Trash'
      expect(targets.target_for('spam')).to eq '[Gmail]/Spam'
      expect(targets).to be_available
    end

    it 'reports archive unavailable when All Mail is hidden from IMAP' do
      hidden = listing.reject { |mailbox| mailbox.name == '[Gmail]/All Mail' }
      targets = described_class.new(listing: hidden, config: config, gmail: true)

      expect(targets.target_for('archive')).to be_nil
      expect(targets.unavailable).to eq ['archive']
    end

    it 'still resolves trash and spam when archive cannot resolve' do
      hidden = listing.reject { |mailbox| mailbox.name == '[Gmail]/All Mail' }
      targets = described_class.new(listing: hidden, config: config, gmail: true)

      expect(targets.target_for('trash')).to eq '[Gmail]/Trash'
      expect(targets.target_for('spam')).to eq '[Gmail]/Spam'
    end

    it 'would call the same inbox unusable if the dialect were ignored' do
      # The regression this class exists to prevent: reading the archive role on a Gmail inbox that
      # archives perfectly well.
      targets = described_class.new(listing: listing, config: config, gmail: false)

      expect(targets.target_for('archive')).to be_nil
      expect(described_class.new(listing: listing, config: config, gmail: true).target_for('archive'))
        .to eq '[Gmail]/All Mail'
    end
  end

  describe '#to_h' do
    it 'keeps the shape Imap::MailboxCommand consumes, including the all key' do
      listing = [
        folder([:Haschildren], 'INBOX'),
        folder([:All, :Hasnochildren], '[Gmail]/All Mail'),
        folder([:Trash, :Hasnochildren], '[Gmail]/Trash'),
        folder([:Junk, :Hasnochildren], '[Gmail]/Spam')
      ]

      expect(described_class.new(listing: listing, config: config, gmail: true).to_h)
        .to eq('archive' => nil, 'trash' => '[Gmail]/Trash', 'spam' => '[Gmail]/Spam', 'all' => '[Gmail]/All Mail')
    end

    it 'ignores a noselect folder when picking All Mail' do
      listing = [
        folder([:Haschildren], 'INBOX'),
        folder([:All, :Noselect], '[Gmail]'),
        folder([:All, :Hasnochildren], '[Gmail]/All Mail')
      ]

      expect(described_class.new(listing: listing, config: config, gmail: true).target_for('archive'))
        .to eq '[Gmail]/All Mail'
    end
  end
end
