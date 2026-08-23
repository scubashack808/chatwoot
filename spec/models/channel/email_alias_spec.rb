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

    # Review finding P2-1. The inbound finder plus-strips the recipient before an exact array
    # containment check, so an alias stored WITH its plus extension can never be matched and the
    # mail is silently dropped. Storage has to use the same spelling the lookup uses.
    it 'strips a plus extension so the stored value is the one the inbound finder looks up' do
      channel = create(:channel_email, account: account, aliases: ['Donations+2026@Example.com'])

      expect(channel.reload.aliases).to eq(['donations@example.com'])
    end

    it 'de-duplicates two plus variants of the same address' do
      channel = create(:channel_email, account: account, aliases: ['donations+2026@example.com', 'donations+gala@example.com'])

      expect(channel.reload.aliases).to eq(['donations@example.com'])
    end

    # Normalising a value that is not an address would REWRITE it into something valid-looking
    # ("info" becomes "info@info", "a@b@c.com" becomes "a@c.com"), so the administrator's own text
    # has to survive to the validation. Green on base; it exists to keep the fix honest.
    it 'leaves a value that is not an address verbatim rather than rewriting it' do
      channel = build(:channel_email, account: account, aliases: ['info', 'a@b@c.com'])
      channel.valid?

      expect(channel.aliases).to eq(['info', 'a@b@c.com'])
    end
  end

  # Review finding P2-1, second half. The UI's vuelidate rule is not a server-side guard, so the
  # API stores whatever it is handed. A malformed alias then appears in the From picker and makes
  # assert_from_address! reject the send.
  describe 'alias format validation' do
    it 'refuses a value with no @' do
      channel = build(:channel_email, account: account, aliases: ['info'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases].join).to include('info')
    end

    it 'refuses a display-name form' do
      channel = build(:channel_email, account: account, aliases: ['"Info" <info@example.com>'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
    end

    it 'refuses a value with an embedded newline' do
      channel = build(:channel_email, account: account, aliases: ["info@example.com\nbcc: attacker@evil.com"])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
    end

    it 'refuses a value with two @ signs instead of silently rewriting it' do
      channel = build(:channel_email, account: account, aliases: ['a@b@c.com'])

      expect(channel).not_to be_valid
      expect(channel.aliases).to eq(['a@b@c.com'])
    end

    it 'accepts a well formed address' do
      channel = build(:channel_email, account: account, aliases: ['info@example.com'])

      expect(channel).to be_valid
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

    # Review finding P2-1, the interaction case. A plus variant normalises INTO the primary, so the
    # existing exclusion rule has to catch it rather than the channel storing an alias that is
    # really its own primary address.
    it 'refuses a plus variant of the channel primary' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: ['sales+ops@example.com'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases].join).to include('primary')
    end

    it 'refuses a plus variant of another channel primary' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: ['care+ops@example.com'])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
    end

    # Review finding P3-1. The router matches forward_to_email with an unordered find_by LIMIT 1,
    # so an alias equal to another inbox's forwarding address gives one address two owners and
    # Postgres picks whichever row it likes.
    it 'refuses an alias that is another channel forwarding address' do
      channel = build(:channel_email, account: account, email: 'sales@example.com', aliases: [existing.forward_to_email])

      expect(channel).not_to be_valid
      expect(channel.errors[:aliases]).to be_present
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
