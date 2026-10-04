require 'rails_helper'

RSpec.describe Campaigns::TriggerOneoffCampaignJob do
  let(:account) { create(:account) }
  let!(:twilio_sms) { create(:channel_twilio_sms, account: account) }
  let!(:twilio_inbox) { create(:inbox, channel: twilio_sms, account: account) }
  let(:label1) { create(:label, account: account) }
  let(:label2) { create(:label, account: account) }

  let!(:campaign) do
    create(:campaign, inbox: twilio_inbox, account: account, audience: [{ type: 'Label', id: label1.id }, { type: 'Label', id: label2.id }])
  end

  it 'enqueues the job' do
    expect { described_class.perform_later(campaign) }.to have_enqueued_job(described_class)
      .on_queue('low')
  end

  context 'when audience preparation fails before sending' do
    let(:provider_messages) { instance_double(Twilio::REST::Api::V2010::AccountContext::MessageList, create: nil) }

    before do
      contact = create(:contact, :with_phone_number, account: account)
      contact.update_labels([label1.title])
      allow(Twilio::REST::Client).to receive(:new).and_return(instance_double(Twilio::REST::Client, messages: provider_messages))
    end

    it 'remains discoverable and sends once on a fresh-record retry' do
      target = campaign
      timestamps = [target.started_at, target.completed_at]
      connection = ActiveRecord::Base.connection
      injected = false
      allow(connection).to receive(:select_all).and_wrap_original do |original, *args, **kwargs|
        query = args.first.respond_to?(:to_sql) ? args.first.to_sql : args.first.to_s
        if !injected && query.include?('FROM "labels"')
          injected = true
          raise ActiveRecord::StatementInvalid, 'transient audience failure'
        end
        original.call(*args, **kwargs)
      end

      expect { described_class.new.perform(target) }.to raise_error(ActiveRecord::StatementInvalid, 'transient audience failure')
      expect(provider_messages).not_to have_received(:create)
      expect(target.reload).to be_active
      expect([target.started_at, target.completed_at]).to eq(timestamps)

      allow(connection).to receive(:select_all).and_call_original
      expect { TriggerScheduledItemsJob.new.perform }.to have_enqueued_job(described_class).with(target)
      described_class.new.perform(Campaign.find(target.id))
      expect(target.reload).to be_completed
      described_class.new.perform(Campaign.find(target.id))
      expect(provider_messages).to have_received(:create).once
    end
  end

  context 'with a generic SMS channel' do
    let(:twilio_sms) { create(:channel_sms, account: account) }

    it 'propagates preparation failure without claiming the campaign and retries safely' do
      contact = create(:contact, :with_phone_number, account: account)
      contact.update_labels([label1.title])
      request = stub_request(:post, 'https://messaging.bandwidth.com/api/v2/users/1/messages')
                .to_return(status: 200, body: { id: '1' }.to_json)
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:select_all).and_wrap_original do |original, *args, **kwargs|
        query = args.first.respond_to?(:to_sql) ? args.first.to_sql : args.first.to_s
        raise ActiveRecord::StatementInvalid, 'audience failure' if query.include?('FROM "labels"')

        original.call(*args, **kwargs)
      end
      expect { described_class.new.perform(campaign) }.to raise_error(ActiveRecord::StatementInvalid, 'audience failure')
      expect(campaign.reload).to be_active
      expect(campaign.started_at).to be_nil
      expect(campaign.completed_at).to be_nil
      expect(request).not_to have_been_requested

      allow(connection).to receive(:select_all).and_call_original
      described_class.new.perform(Campaign.find(campaign.id))
      expect(campaign.reload).to be_completed
      described_class.new.perform(Campaign.find(campaign.id))
      expect(request).to have_been_requested.once
    end
  end

  it 'keeps an interrupted delivery processing and does not resend on retry' do
    create_list(:contact, 2, :with_phone_number, account: account).each { |contact| contact.update_labels([label1.title]) }
    messages = instance_double(Twilio::REST::Api::V2010::AccountContext::MessageList)
    allow(Twilio::REST::Client).to receive(:new).and_return(instance_double(Twilio::REST::Client, messages: messages))
    attempts = 0
    allow(messages).to receive(:create) do
      expect(Campaign.find(campaign.id)).to be_processing
      attempts += 1
      raise 'unexpected delivery failure' if attempts == 2
    end

    expect { described_class.new.perform(campaign) }.to raise_error('unexpected delivery failure')
    expect(campaign.reload).to be_processing
    expect(campaign.completed_at).to be_nil
    described_class.new.perform(Campaign.find(campaign.id))
    expect(messages).to have_received(:create).twice
  end

  context 'when called with a campaign' do
    it 'triggers the campaign' do
      expect(campaign).to receive(:trigger!)
      described_class.perform_now(campaign)
    end
  end
end
