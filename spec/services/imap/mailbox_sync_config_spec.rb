require 'rails_helper'

RSpec.describe Imap::MailboxSyncConfig do
  describe '.parse' do
    it 'treats nil as the default off configuration' do
      config = described_class.parse(nil)

      expect(config.mode).to eq 'off'
      expect(config.sent_mode).to eq 'provider_managed'
      expect(config.folder_overrides).to eq({})
    end

    it 'treats an empty hash as the default off configuration' do
      expect(described_class.parse({}).mode).to eq 'off'
    end

    it 'accepts string keys as stored in jsonb' do
      config = described_class.parse('mode' => 'observe', 'sent_mode' => 'append',
                                     'folder_overrides' => { 'archive' => 'INBOX.Archives' })

      expect(config.mode).to eq 'observe'
      expect(config.sent_mode).to eq 'append'
      expect(config.override_for(:archive)).to eq 'INBOX.Archives'
    end

    it 'accepts symbol keys' do
      config = described_class.parse(mode: 'active', folder_overrides: { trash: 'INBOX.Trash' })

      expect(config.mode).to eq 'active'
      expect(config.override_for('trash')).to eq 'INBOX.Trash'
    end

    it 'rejects a non-hash payload' do
      expect { described_class.parse('off') }.to raise_error(described_class::InvalidConfigError, /object/)
    end

    describe 'mode' do
      it 'accepts every supported mode' do
        %w[off observe active].each do |mode|
          expect(described_class.parse(mode: mode).mode).to eq mode
        end
      end

      it 'rejects an unsupported mode' do
        expect { described_class.parse(mode: 'archive_everything') }
          .to raise_error(described_class::InvalidConfigError, /mode/)
      end

      it 'rejects a blank mode rather than silently defaulting' do
        expect { described_class.parse(mode: '') }.to raise_error(described_class::InvalidConfigError, /mode/)
      end
    end

    describe 'sent_mode' do
      it 'accepts every supported sent mode' do
        %w[provider_managed append disabled].each do |sent_mode|
          expect(described_class.parse(sent_mode: sent_mode).sent_mode).to eq sent_mode
        end
      end

      it 'rejects an unsupported sent mode' do
        expect { described_class.parse(sent_mode: 'guess') }
          .to raise_error(described_class::InvalidConfigError, /sent_mode/)
      end
    end

    describe 'unknown keys' do
      it 'rejects an unknown top level key' do
        expect { described_class.parse(mode: 'off', archive_folder: 'INBOX.Archive') }
          .to raise_error(described_class::InvalidConfigError, /archive_folder/)
      end

      it 'rejects an unknown folder role' do
        expect { described_class.parse(folder_overrides: { drafts: 'INBOX.Drafts' }) }
          .to raise_error(described_class::InvalidConfigError, /drafts/)
      end
    end

    describe 'folder overrides' do
      it 'accepts every supported role' do
        overrides = { 'archive' => 'INBOX.Archive', 'trash' => 'INBOX.Trash',
                      'spam' => 'INBOX.spam', 'sent' => 'INBOX.Sent' }

        expect(described_class.parse(folder_overrides: overrides).folder_overrides).to eq overrides
      end

      it 'rejects a non-hash folder_overrides' do
        expect { described_class.parse(folder_overrides: 'INBOX.Archive') }
          .to raise_error(described_class::InvalidConfigError, /folder_overrides/)
      end

      it 'rejects a non-string folder name' do
        expect { described_class.parse(folder_overrides: { archive: 3 }) }
          .to raise_error(described_class::InvalidConfigError, /archive/)
      end

      it 'drops a blank override so the role stays unconfigured rather than guessed' do
        config = described_class.parse(folder_overrides: { archive: '', trash: nil, spam: '   ' })

        expect(config.folder_overrides).to eq({})
        expect(config.override_for(:archive)).to be_nil
      end

      it 'preserves exact server folder names including spaces and non-ascii' do
        overrides = { 'archive' => '[Gmail]/All Mail', 'trash' => 'INBOX.Papierkorb' }
        config = described_class.parse(folder_overrides: overrides)

        expect(config.override_for(:archive)).to eq '[Gmail]/All Mail'
        expect(config.override_for(:trash)).to eq 'INBOX.Papierkorb'
      end
    end
  end

  describe 'mode predicates' do
    it 'reports off' do
      config = described_class.parse(mode: 'off')

      expect(config).to be_off
      expect(config).not_to be_active
      expect(config.discovery_allowed?).to be false
      expect(config.provider_mutation_allowed?).to be false
    end

    it 'allows observation but never provider mutation in observe mode' do
      config = described_class.parse(mode: 'observe')

      expect(config).to be_observe
      expect(config.discovery_allowed?).to be true
      expect(config.provider_mutation_allowed?).to be false
    end

    it 'allows provider mutation only in active mode' do
      config = described_class.parse(mode: 'active')

      expect(config).to be_active
      expect(config.discovery_allowed?).to be true
      expect(config.provider_mutation_allowed?).to be true
    end
  end

  describe '#restore_target' do
    it 'is always INBOX and is never taken from an override or a special-use attribute' do
      config = described_class.parse(folder_overrides: { archive: 'INBOX.Archive' })

      expect(config.restore_target).to eq 'INBOX'
    end

    it 'is INBOX even when the configuration is otherwise empty' do
      expect(described_class.parse(nil).restore_target).to eq 'INBOX'
    end
  end

  describe '#to_h' do
    it 'round trips through parse' do
      raw = { 'mode' => 'observe', 'sent_mode' => 'append',
              'folder_overrides' => { 'archive' => 'INBOX.Archives' } }

      expect(described_class.parse(described_class.parse(raw).to_h).to_h).to eq raw
    end

    it 'always emits string keys so it stores cleanly as jsonb' do
      config = described_class.parse(mode: :off, folder_overrides: { archive: 'INBOX.Archive' })

      expect(config.to_h.keys).to all(be_a(String))
      expect(config.to_h['folder_overrides'].keys).to all(be_a(String))
    end

    it 'never carries a credential or token field' do
      expect(described_class::PERMITTED_KEYS).to contain_exactly('mode', 'sent_mode', 'folder_overrides')
    end
  end

  describe '.default' do
    it 'is off with no overrides, matching the stored column default' do
      expect(described_class.default.to_h).to eq(
        'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => {}
      )
    end
  end
end
