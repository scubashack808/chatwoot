require 'rails_helper'

RSpec.describe Imap::MessageIdentity do
  let(:location) do
    { 'mailbox' => 'INBOX', 'uidvalidity' => 42, 'uid' => 7, 'roles' => ['inbox'] }
  end

  describe '.build' do
    it 'records the exact mailbox, uidvalidity and uid' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7)

      expect(identity.mailbox).to eq 'INBOX'
      expect(identity.uidvalidity).to eq 42
      expect(identity.uid).to eq 7
    end

    it 'starts at identity version 1' do
      expect(described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7).version).to eq 1
    end

    it 'records the special use roles for the mailbox' do
      identity = described_class.build(mailbox: 'INBOX.Archive', uidvalidity: 42, uid: 7, roles: ['archive'])

      expect(identity.roles).to eq ['archive']
    end

    it 'records a provider stable id when the server offers one' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, provider_id: '1234567890')

      expect(identity.provider_id).to eq '1234567890'
    end

    it 'seeds locations from the primary location' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])

      expect(identity.locations).to eq [location]
    end

    it 'marks the identity verified at build time' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7)

      expect(identity.sync_state).to eq 'verified'
      expect(identity.last_verified_at).to be_present
    end

    it 'coerces uid and uidvalidity to integers' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: '42', uid: '7')

      expect(identity.uidvalidity).to eq 42
      expect(identity.uid).to eq 7
    end
  end

  describe 'the serialised payload' do
    subject(:payload) { described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']).to_h }

    it 'uses string keys so it stores cleanly as jsonb' do
      expect(payload.keys).to all(be_a(String))
    end

    it 'never contains a sequence number' do
      expect(payload.to_s).not_to match(/seqno|sequence/i)
    end

    it 'keeps the flat primary fields consistent with the first location' do
      expect(payload['mailbox']).to eq payload['locations'].first['mailbox']
      expect(payload['uid']).to eq payload['locations'].first['uid']
      expect(payload['uidvalidity']).to eq payload['locations'].first['uidvalidity']
    end

    it 'round trips through parse' do
      expect(described_class.parse(payload).to_h).to eq payload
    end
  end

  describe '.parse' do
    it 'returns nil for a blank payload' do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse({})).to be_nil
    end

    it 'reads a stored payload back' do
      stored = described_class.build(mailbox: 'INBOX.Trash', uidvalidity: 9, uid: 3, roles: ['trash']).to_h

      identity = described_class.parse(stored)

      expect(identity.mailbox).to eq 'INBOX.Trash'
      expect(identity.uid).to eq 3
      expect(identity.roles).to eq ['trash']
    end
  end

  describe '#stale_for?' do
    subject(:identity) { described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7) }

    # A UIDVALIDITY change means every UID in that mailbox is meaningless. The stored UID must
    # never be reused against the new generation.
    it 'is stale when the mailbox uidvalidity has changed' do
      expect(identity.stale_for?(mailbox: 'INBOX', uidvalidity: 43)).to be true
    end

    it 'is not stale when the uidvalidity still matches' do
      expect(identity.stale_for?(mailbox: 'INBOX', uidvalidity: 42)).to be false
    end

    it 'is not stale for a different mailbox it does not claim' do
      expect(identity.stale_for?(mailbox: 'INBOX.Archive', uidvalidity: 99)).to be false
    end
  end

  describe '#with_location' do
    subject(:identity) { described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']) }

    it 'adds a second location, because one Gmail message can appear in more than one mailbox' do
      updated = identity.with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 42, uid: 99, roles: ['all'])

      expect(updated.locations.length).to eq 2
      expect(updated.locations.map { |l| l['mailbox'] }).to contain_exactly('INBOX', '[Gmail]/All Mail')
    end

    it 'increments the identity version' do
      expect(identity.with_location(mailbox: 'X', uidvalidity: 1, uid: 1).version).to eq 2
    end

    it 'replaces a location for the same mailbox rather than duplicating it' do
      updated = identity.with_location(mailbox: 'INBOX', uidvalidity: 43, uid: 8)

      expect(updated.locations.length).to eq 1
      expect(updated.uid).to eq 8
      expect(updated.uidvalidity).to eq 43
    end

    it 'keeps the flat primary fields pointing at the first location' do
      updated = identity.with_location(mailbox: 'INBOX', uidvalidity: 43, uid: 8)

      expect(updated.to_h['mailbox']).to eq updated.to_h['locations'].first['mailbox']
      expect(updated.to_h['uid']).to eq updated.to_h['locations'].first['uid']
    end
  end

  describe '#version' do
    it 'increases monotonically as the identity is updated' do
      identity = described_class.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7)
      versions = 3.times.each_with_object([identity]) { |_, acc| acc << acc.last.with_location(mailbox: 'INBOX', uidvalidity: 42, uid: 7) }

      expect(versions.map(&:version)).to eq [1, 2, 3, 4]
    end
  end
end
