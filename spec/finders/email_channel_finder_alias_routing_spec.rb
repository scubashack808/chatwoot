require 'rails_helper'

# Row 09 behaviour A01: To, Cc, Bcc and X-Original-To all route to the channel that owns the
# address, whether it is the primary or one of its aliases.
RSpec.describe EmailChannelFinder do
  let(:account) { create(:account) }
  let!(:channel) do
    create(:channel_email, account: account, email: 'care@example.com', aliases: ['nonprofit@example.com'])
  end
  let!(:other_channel) { create(:channel_email, account: account, email: 'sales@example.com') }

  def mail_with(headers)
    Mail.new({ from: 'customer@example.com', subject: 'Hello', body: 'Hi' }.merge(headers))
  end

  def channel_for(headers)
    described_class.new(mail_with(headers)).perform
  end

  it 'routes To addressed to an alias' do
    expect(channel_for(to: 'nonprofit@example.com')).to eq(channel)
  end

  it 'routes Cc addressed to an alias' do
    expect(channel_for(to: 'someone@example.com', cc: 'nonprofit@example.com')).to eq(channel)
  end

  it 'routes Bcc addressed to an alias' do
    expect(channel_for(to: 'someone@example.com', bcc: 'nonprofit@example.com')).to eq(channel)
  end

  it 'routes X-Original-To addressed to an alias' do
    headers = { to: 'someone@example.com' }.merge('X-Original-To' => 'nonprofit@example.com')

    expect(channel_for(headers)).to eq(channel)
  end

  it 'matches an alias case-insensitively' do
    expect(channel_for(to: 'NonProfit@Example.COM')).to eq(channel)
  end

  it 'matches a plus-addressed alias' do
    expect(channel_for(to: 'nonprofit+donation@example.com')).to eq(channel)
  end

  it 'still routes the primary address' do
    expect(channel_for(to: 'care@example.com')).to eq(channel)
  end

  it 'still routes the forward-to address' do
    expect(channel_for(to: channel.forward_to_email)).to eq(channel)
  end

  it 'routes another channel primary to that channel, not to the alias owner' do
    expect(channel_for(to: 'sales@example.com')).to eq(other_channel)
  end

  it 'routes nothing for an address no channel owns' do
    expect(channel_for(to: 'stranger@example.com')).to be_nil
  end
end
