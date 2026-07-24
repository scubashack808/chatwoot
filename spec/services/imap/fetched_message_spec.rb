require 'rails_helper'

RSpec.describe Imap::FetchedMessage do
  subject(:fetched) do
    described_class.new(mail: mail, mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
  end

  let(:raw) { Rails.root.join('spec/fixtures/files/only_text.eml').read }
  let(:mail) { Mail.read_from_string(raw) }

  describe 'the parsed mail' do
    it 'carries the parsed mail through' do
      expect(fetched.mail).to eq mail
    end

    it 'delegates message_id so it can stand in for the mail object' do
      expect(fetched.message_id).to eq mail.message_id
    end

    it 'delegates from' do
      expect(fetched.from).to eq mail.from
    end
  end

  describe 'the server coordinates' do
    it 'carries the exact mailbox name, uidvalidity and uid' do
      expect(fetched.mailbox).to eq 'INBOX'
      expect(fetched.uidvalidity).to eq 42
      expect(fetched.uid).to eq 7
    end

    it 'carries the special use roles of the mailbox' do
      expect(fetched.roles).to eq ['inbox']
    end

    it 'carries a provider stable id when the server offered one' do
      gmail = described_class.new(mail: mail, mailbox: '[Gmail]/All Mail', uidvalidity: 1, uid: 2, provider_id: '98765')

      expect(gmail.provider_id).to eq '98765'
    end

    it 'has no provider id when the server offered none' do
      expect(fetched.provider_id).to be_nil
    end

    it 'exposes no sequence number at all' do
      expect(fetched).not_to respond_to(:seqno)
      expect(fetched).not_to respond_to(:sequence_number)
    end
  end

  describe '#to_identity' do
    it 'builds the identity that gets persisted with the message' do
      identity = fetched.to_identity

      expect(identity).to be_a(Imap::MessageIdentity)
      expect(identity.mailbox).to eq 'INBOX'
      expect(identity.uidvalidity).to eq 42
      expect(identity.uid).to eq 7
      expect(identity.roles).to eq ['inbox']
    end

    it 'carries the provider id into the identity' do
      gmail = described_class.new(mail: mail, mailbox: '[Gmail]/All Mail', uidvalidity: 1, uid: 2, provider_id: '98765')

      expect(gmail.to_identity.provider_id).to eq '98765'
    end
  end
end
