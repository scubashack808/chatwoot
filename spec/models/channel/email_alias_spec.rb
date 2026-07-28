require 'rails_helper'

# Row 09 behaviours B03 and A01 (model half) plus A02/A03/A04 address selection.
RSpec.describe Channel::Email do
  let(:account) { create(:account) }

  describe 'aliases column' do
    it 'defaults to an empty array' do
      channel = create(:channel_email, account: account)

      expect(channel.reload.aliases).to eq([])
    end

    it 'stores multiple addresses' do
      channel = create(:channel_email, account: account, aliases: ['nonprofit@example.com', 'info@example.com'])

      expect(channel.reload.aliases).to contain_exactly('nonprofit@example.com', 'info@example.com')
    end
  end

  describe 'alias normalisation' do
    it 'downcases, strips, removes blanks and de-duplicates' do
      channel = create(:channel_email, account: account, aliases: ['  NonProfit@Example.com ', '', 'nonprofit@example.com', nil])

      expect(channel.aliases).to eq(['nonprofit@example.com'])
    end
  end

  describe 'alias uniqueness' do
    let!(:existing) do
      create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com'])
    end

    it 'refuses an alias equal to the channel primary' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: ['SALES@example.com'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases].join).to include('primary')
    end

    it 'refuses an alias already used as another channel alias' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: ['nonprofit@example.com'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
    end

    it 'refuses an alias equal to another channel primary' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: ['care@example.com'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
    end

    it 'refuses a primary that is already another channel alias' do
      channel = build(:channel_email, account: account, email: 'nonprofit@example.com')

      expect(channel).not_to be_valid
      expect(channel.errors[:email]).to be_present
    end

    it 'lets the owning channel save its own aliases again' do
      existing.aliases = ['nonprofit@example.com', 'donate@example.com']

      expect(existing).to be_valid
    end
  end

  describe '#all_addresses' do
    it 'returns the primary followed by the aliases' do
      channel = create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com'])

      expect(channel.all_addresses).to eq(['care@example.com', 'nonprofit@example.com'])
    end
  end

  describe '#owned_address' do
    let(:channel) { create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com']) }

    it 'returns the canonical address for a case-different match' do
      expect(channel.owned_address('NonProfit@Example.COM')).to eq('nonprofit@example.com')
    end

    it 'returns the canonical address for a plus-addressed match' do
      expect(channel.owned_address('nonprofit+donation@example.com')).to eq('nonprofit@example.com')
    end

    it 'returns nil for an address the channel does not own' do
      expect(channel.owned_address('stranger@example.com')).to be_nil
    end

    it 'returns nil for a blank candidate' do
      expect(channel.owned_address(nil)).to be_nil
    end
  end

  describe '#outbound_address_for' do
    let(:channel) { create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com']) }
    let(:inbox) { channel.inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }

    def incoming_email(to:)
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, content_type: :incoming_email,
                       content_attributes: { email: { to: to, cc: [], bcc: [] } })
    end

    it 'falls back to the primary when nothing else is known' do
      expect(channel.outbound_address_for(conversation)).to eq('care@example.com')
    end

    it 'uses the alias the latest inbound message arrived at' do
      incoming_email(to: ['nonprofit@example.com'])

      expect(channel.outbound_address_for(conversation)).to eq('nonprofit@example.com')
    end

    it 'prefers an agent override that the channel owns' do
      incoming_email(to: ['nonprofit@example.com'])
      message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                 message_type: :outgoing, content_attributes: { from_email: 'care@example.com' })

      expect(channel.outbound_address_for(conversation, message: message)).to eq('care@example.com')
    end

    it 'ignores a stored override the channel does not own and never emits it' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                 message_type: :outgoing, content_attributes: { from_email: 'attacker@evil.com' })

      expect(channel.outbound_address_for(conversation, message: message)).to eq('care@example.com')
    end

    it 'ignores an inbound address the channel does not own' do
      incoming_email(to: ['someone-else@example.com'])

      expect(channel.outbound_address_for(conversation)).to eq('care@example.com')
    end
  end
end
