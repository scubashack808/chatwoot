require 'rails_helper'

RSpec.describe 'Webhooks::SmsController', type: :request do
  describe 'POST /webhooks/sms/{:phone_number}' do
    it 'call the sms events job with the params' do
      allow(Webhooks::SmsEventsJob).to receive(:perform_later)
      expect(Webhooks::SmsEventsJob).to receive(:perform_later)
      post '/webhooks/sms/123221321', params: { content: 'hello' }
      expect(response).to have_http_status(:success)
    end
  end

  describe 'Bandwidth callbacks through the queued job' do
    let!(:channel) { create(:channel_sms, phone_number: '+15550000001') }
    let(:conversation) { create(:conversation, inbox: channel.inbox, account: channel.account) }
    let!(:message) do
      create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation,
                       message_type: :outgoing, status: :sent, source_id: 'bandwidth-synthetic-1')
    end
    let(:outbound_message) do
      { id: 'bandwidth-synthetic-1', owner: '+15550000001', from: '+15550000001', to: ['+15550000002'],
        direction: 'out', text: 'Synthetic message', applicationId: '1', time: '2026-10-04T00:00:00Z', segmentCount: 1 }
    end
    let(:delivered_event) do
      { type: 'message-delivered', time: '2026-10-04T00:00:01Z', to: '+15550000002',
        description: 'Message delivered to handset.', message: outbound_message }
    end
    let(:failed_event) do
      { type: 'message-failed', time: '2026-10-04T00:00:01Z', to: '+15550000002',
        description: 'Undeliverable', errorCode: 995, message: outbound_message }
    end

    def post_and_perform(event)
      clear_enqueued_jobs
      post "/webhooks/sms/#{channel.phone_number}", params: [event], as: :json
      expect(response).to have_http_status(:ok)
      queued = enqueued_jobs.find { |job| job[:job] == Webhooks::SmsEventsJob }
      Webhooks::SmsEventsJob.perform_now(*ActiveJob::Arguments.deserialize(queued[:args]))
    end

    it 'marks the outgoing message delivered' do
      post_and_perform(delivered_event)

      expect(message.reload.status).to eq('delivered')
      expect(message.external_error).to be_nil
    end

    it 'marks the outgoing message failed with the provider error' do
      post_and_perform(failed_event)

      expect(message.reload.status).to eq('failed')
      expect(message.external_error).to eq('995 - Undeliverable')
    end

    it 'updates only the sending inbox when the recipient number is another channel' do
      recipient_channel = create(:channel_sms, phone_number: '+15550000002', account: channel.account)
      recipient_conversation = create(:conversation, inbox: recipient_channel.inbox, account: channel.account)
      recipient_message = create(:message, account: channel.account, inbox: recipient_channel.inbox,
                                           conversation: recipient_conversation, message_type: :outgoing,
                                           status: :sent, source_id: 'bandwidth-synthetic-1')

      post_and_perform(delivered_event)

      expect(message.reload.status).to eq('delivered')
      expect(recipient_message.reload.status).to eq('sent')
    end

    it 'persists an inbound message in the receiving channel' do
      event = { type: 'message-received', time: '2026-10-04T00:00:00Z', to: '+15550000001',
                description: 'Incoming message received',
                message: { id: 'bandwidth-inbound-control', owner: '+15550000001', from: '+15550000002',
                           to: ['+15550000001'], direction: 'in', text: 'Inbound control', applicationId: '1',
                           time: '2026-10-04T00:00:00Z', segmentCount: 1 } }

      post_and_perform(event)

      expect(channel.inbox.messages.incoming.find_by!(source_id: 'bandwidth-inbound-control').content).to eq('Inbound control')
    end
  end
end
